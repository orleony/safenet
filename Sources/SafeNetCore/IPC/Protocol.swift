import Foundation

/// Command line of the `SafeNetApp <command>` client and the wire format spoken with the running
/// app over the unix socket. Pure and strict: nothing here touches the system.
public enum CLICommand: Equatable {
    case status
    /// nil = the current (confirmed) IP; otherwise an IP / CIDR, or an uppercased two-letter country.
    case allow(String?)
    case panel
    case config
    case version

    /// Commands the client runs without a server.
    public var isLocal: Bool { self == .config || self == .version }
}

public let cliUsage = """
Использование: SafeNetApp <команда>
  status                 состояние защиты, IP и страна
  allow                  разрешить текущий IP
  allow <IP|подсеть>     разрешить IP (1.2.3.4) или подсеть (185.12.40.0/24)
  allow <страна>         разрешить страну (двухбуквенный код, например NL)
  panel                  открыть окно настроек
  config                 путь к config.yaml
  version                версия
"""

/// Command-line arguments (without argv[0]) -> command; nil for anything unknown or malformed
/// (the client prints `cliUsage`, exit code 2).
public func parseCLI(_ args: [String]) -> CLICommand? {
    guard let first = args.first else { return nil }
    let rest = Array(args.dropFirst())
    switch first {
    case "status": return rest.isEmpty ? .status : nil
    case "panel": return rest.isEmpty ? .panel : nil
    case "config": return rest.isEmpty ? .config : nil
    case "version", "--version": return rest.isEmpty ? .version : nil
    case "allow":
        if rest.isEmpty { return .allow(nil) }
        guard rest.count == 1, let t = normalizeAllowTarget(rest[0]) else { return nil }
        return .allow(t)
    default: return nil
    }
}

/// "NL"/"nl" -> "NL"; an IPv4/IPv6 address or CIDR (validated by `IPMatcher`) as it is; else nil.
public func normalizeAllowTarget(_ raw: String) -> String? {
    guard raw.utf8.count <= 64 else { return nil }
    if raw.utf8.count == 2 {
        let u = raw.uppercased()
        return u.utf8.allSatisfy({ $0 >= 65 && $0 <= 90 }) ? u : nil
    }
    return IPMatcher.isValidEntry(raw) ? raw : nil
}

// MARK: - Messages

public let ipcVersion = 1
/// A request or response larger than this is refused (and the reader stops reading).
public let ipcMaxMessage = 64 * 1024

public struct IPCRequest: Codable, Equatable {
    public var v: Int
    public var cmd: String
    public var arg: String?
    public init(v: Int = ipcVersion, cmd: String, arg: String? = nil) { self.v = v; self.cmd = cmd; self.arg = arg }

    public init(_ c: CLICommand) {
        switch c {
        case .status: self.init(cmd: "status")
        case .allow(let t): self.init(cmd: "allow", arg: t)
        case .panel: self.init(cmd: "panel")
        case .config: self.init(cmd: "config")
        case .version: self.init(cmd: "version")
        }
    }

    /// Strict: unknown cmd, an argument where none belongs or a malformed target -> nil.
    public var command: CLICommand? {
        guard v == ipcVersion else { return nil }
        switch cmd {
        case "status": return arg == nil ? .status : nil
        case "panel": return arg == nil ? .panel : nil
        case "config": return arg == nil ? .config : nil
        case "version": return arg == nil ? .version : nil
        case "allow":
            guard let a = arg else { return .allow(nil) }
            guard let t = normalizeAllowTarget(a) else { return nil }
            return .allow(t)
        default: return nil
        }
    }
}

public struct IPCResponse: Codable, Equatable {
    public var ok: Bool
    public var text: String
    public var data: [String: String]?
    public init(ok: Bool, text: String, data: [String: String]? = nil) { self.ok = ok; self.text = text; self.data = data }
    public static func error(_ t: String) -> IPCResponse { IPCResponse(ok: false, text: t) }
}

public enum IPCDecodeError: Error, Equatable, CustomStringConvertible {
    case tooLarge, garbled, badVersion, unknownCommand
    public var description: String {
        switch self {
        case .tooLarge: return "сообщение слишком большое"
        case .garbled: return "непонятное сообщение"
        case .badVersion: return "несовместимая версия протокола"
        case .unknownCommand: return "неизвестная команда или аргумент"
        }
    }
}

/// One JSON object on one line, newline-terminated.
public func encodeMessage<T: Encodable>(_ m: T) -> Data {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    var d = (try? e.encode(m)) ?? Data("{}".utf8)
    d.append(0x0A)
    return d
}

private func decodeLine<T: Decodable>(_ data: Data, as: T.Type) throws -> T {
    guard data.count <= ipcMaxMessage else { throw IPCDecodeError.tooLarge }
    var d = data
    while let l = d.last, l == 0x0A || l == 0x0D { d.removeLast() }
    guard !d.isEmpty, !d.contains(0x0A) else { throw IPCDecodeError.garbled }
    do { return try JSONDecoder().decode(T.self, from: d) } catch { throw IPCDecodeError.garbled }
}

public func decodeRequest(_ data: Data) throws -> CLICommand {
    let r = try decodeLine(data, as: IPCRequest.self)
    guard r.v == ipcVersion else { throw IPCDecodeError.badVersion }
    guard let c = r.command else { throw IPCDecodeError.unknownCommand }
    return c
}

public func decodeResponse(_ data: Data) throws -> IPCResponse {
    try decodeLine(data, as: IPCResponse.self)
}
