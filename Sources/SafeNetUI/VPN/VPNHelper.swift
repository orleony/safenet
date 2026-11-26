import Foundation
import Darwin
import SafeNetCore

// Built-in VPN: a root helper (LaunchDaemon `local.safenet.vpn`) runs sing-box with a TUN
// interface; the app talks to it over a unix socket. Same binary as the app:
// `SafeNetVPNHelper --vpn-helper <uid>` (a copy in /Library/PrivilegedHelperTools, root-owned, so
// nothing the user's account can write is ever run as root).
//
// Security: the socket is 0666 but every connection's peer uid must be the installing user's (or
// root); the helper builds the sing-box config itself from a validated `VPNStartRequest`
// (`SingBoxConfig.validate`), it never takes a config or a file path.

public enum VPNHelperPaths {
    public static let label = "local.safenet.vpn"
    public static let installDir = "/Library/PrivilegedHelperTools/local.safenet.vpn"
    public static var helperBinary: String { installDir + "/SafeNetVPNHelper" }
    public static var singBox: String { installDir + "/sing-box" }
    public static var singBoxVersionFile: String { installDir + "/VERSION" }
    public static let plist = "/Library/LaunchDaemons/local.safenet.vpn.plist"
    public static let workDir = "/Library/Application Support/SafeNet VPN"
    public static let socket = "/var/run/local.safenet.vpn.sock"
    public static let log = "/Library/Logs/SafeNet/vpn.log"
}

/// Bumped whenever the helper's protocol or behaviour changes: the app then reinstalls it.
public enum VPNHelperVersion {
    public static let protocolVersion = 1
}

public struct VPNHelperStatus: Codable, Equatable {
    public enum State: String, Codable { case stopped, starting, running, failed }
    public var state: State
    public var message: String?
    public var since: Date?
    public var protocolVersion: Int
    public var singBoxVersion: String
    public init(state: State, message: String? = nil, since: Date? = nil, protocolVersion: Int = VPNHelperVersion.protocolVersion,
                singBoxVersion: String = "") {
        self.state = state; self.message = message; self.since = since
        self.protocolVersion = protocolVersion; self.singBoxVersion = singBoxVersion
    }
}

struct VPNHelperRequest: Codable {
    var cmd: String                 // "status" | "start" | "stop"
    var start: VPNStartRequest?
}

struct VPNHelperResponse: Codable {
    var ok: Bool
    var error: String?
    var status: VPNHelperStatus?
}

// MARK: - Client (app side)

public enum VPNHelperClient {
    public enum Failure: Error, Equatable { case notInstalled, timeout, protocolError(String), refused(String) }

    static func exchange(_ req: VPNHelperRequest, timeout: TimeInterval) -> Result<VPNHelperStatus, Failure> {
        guard var data = try? JSONEncoder().encode(req) else { return .failure(.protocolError("encode")) }
        data.append(0x0A)
        switch IPCClient.exchange(data, path: VPNHelperPaths.socket, timeout: timeout) {
        case .failure(.notRunning): return .failure(.notInstalled)
        case .failure(.timeout): return .failure(.timeout)
        case .failure(.protocolError(let m)): return .failure(.protocolError(m))
        case .success(let line):
            guard let r = try? JSONDecoder.vpn.decode(VPNHelperResponse.self, from: line) else {
                return .failure(.protocolError("непонятный ответ помощника"))
            }
            if !r.ok { return .failure(.refused(r.error ?? "помощник отказал")) }
            guard let s = r.status else { return .failure(.protocolError("нет статуса")) }
            return .success(s)
        }
    }

    public static func status() -> Result<VPNHelperStatus, Failure> { exchange(VPNHelperRequest(cmd: "status"), timeout: 2) }
    public static func start(_ r: VPNStartRequest) -> Result<VPNHelperStatus, Failure> {
        exchange(VPNHelperRequest(cmd: "start", start: r), timeout: 12)
    }
    public static func stop() -> Result<VPNHelperStatus, Failure> { exchange(VPNHelperRequest(cmd: "stop"), timeout: 8) }
}

extension JSONDecoder {
    static var vpn: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }
}
extension JSONEncoder {
    static var vpn: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }
}

// MARK: - Daemon (root side)

/// Runs sing-box and keeps it running: a crash restarts it (2 s, then up to 30 s between tries)
/// with the same request until `stop`.
final class SingBoxSupervisor {
    private let queue = DispatchQueue(label: "safenet.vpn.supervisor")
    private let singBox: String
    private let workDir: String
    private let logPath: String
    private var process: Process?
    private var request: VPNStartRequest?
    private var status = VPNHelperStatus(state: .stopped)
    private var restartDelay: TimeInterval = 2
    private var generation = 0

    init(singBox: String = VPNHelperPaths.singBox, workDir: String = VPNHelperPaths.workDir, logPath: String = VPNHelperPaths.log) {
        self.singBox = singBox; self.workDir = workDir; self.logPath = logPath
        status.singBoxVersion = (try? String(contentsOfFile: VPNHelperPaths.singBoxVersionFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func currentStatus() -> VPNHelperStatus { queue.sync { status } }

    /// Validates, writes the config, (re)starts sing-box and waits up to ~2 s to see it stay up.
    func start(_ r: VPNStartRequest) -> Result<VPNHelperStatus, ProxyLinkError> {
        do { try SingBoxConfig.validate(r) } catch { return .failure((error as? ProxyLinkError) ?? ProxyLinkError("\(error)")) }
        queue.sync {
            request = r
            restartDelay = 2
            stopLocked()
            launchLocked()
        }
        Thread.sleep(forTimeInterval: 2)
        return .success(currentStatus())
    }

    func stop() -> VPNHelperStatus {
        queue.sync {
            request = nil
            stopLocked()
            status.state = .stopped; status.message = nil; status.since = Date()
            return status
        }
    }

    private func launchLocked() {
        guard let r = request else { return }
        generation += 1
        let gen = generation
        let fm = FileManager.default
        try? fm.createDirectory(atPath: workDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.createDirectory(atPath: (logPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o755])
        let config = (workDir as NSString).appendingPathComponent("config.json")
        let data = SingBoxConfig.build(r).encoded(pretty: true)
        guard fm.createFile(atPath: config, contents: data, attributes: [.posixPermissions: 0o600]) else {
            status = VPNHelperStatus(state: .failed, message: "не удалось записать конфигурацию", since: Date(),
                                     singBoxVersion: status.singBoxVersion)
            return
        }
        fm.createFile(atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o644])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: singBox)
        p.arguments = ["run", "-c", config, "-D", workDir, "--disable-color"]
        if let h = FileHandle(forWritingAtPath: logPath) { p.standardOutput = h; p.standardError = h }
        p.terminationHandler = { [weak self] proc in self?.exited(gen, code: proc.terminationStatus) }
        do {
            try p.run()
            process = p
            status = VPNHelperStatus(state: .running, message: nil, since: Date(), singBoxVersion: status.singBoxVersion)
        } catch {
            status = VPNHelperStatus(state: .failed, message: "sing-box не запустился: \(error.localizedDescription)", since: Date(),
                                     singBoxVersion: status.singBoxVersion)
        }
    }

    private func stopLocked() {
        generation += 1                       // the old process's exit is no longer ours
        guard let p = process else { return }
        process = nil
        if p.isRunning {
            p.terminate()
            let end = Date().addingTimeInterval(3)
            while p.isRunning && Date() < end { usleep(50_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }

    private func exited(_ gen: Int, code: Int32) {
        queue.async { [self] in
            guard gen == generation, request != nil else { return }
            process = nil
            status = VPNHelperStatus(state: .failed, message: "sing-box остановился (код \(code)): \(lastLogLine())",
                                     since: Date(), singBoxVersion: status.singBoxVersion)
            let delay = restartDelay
            restartDelay = min(30, restartDelay * 2)
            queue.asyncAfter(deadline: .now() + delay) { [self] in
                guard gen + 0 == generation, request != nil, process == nil else { return }
                status.state = .starting
                launchLocked()
            }
        }
    }

    /// Last meaningful line of sing-box's log (shown as the failure reason).
    func lastLogLine() -> String {
        guard let d = FileManager.default.contents(atPath: logPath) else { return "нет журнала" }
        let lines = String(decoding: d.suffix(8192), as: UTF8.self).split(separator: "\n").map(String.init)
        let line = lines.last { $0.contains("FATAL") || $0.contains("ERROR") } ?? lines.last ?? ""
        return String(line.prefix(300))
    }

    func shutdown() { _ = stop() }
}

public enum VPNHelperDaemon {
    /// `SafeNetVPNHelper --vpn-helper <uid>`: serves the socket until SIGTERM (then stops sing-box).
    public static func run(arguments: [String]) -> Int32 {
        guard getuid() == 0 else { FileHandle.standardError.write(Data("vpn helper must run as root\n".utf8)); return 2 }
        guard let first = arguments.first, let uid = uid_t(first) else {
            FileHandle.standardError.write(Data("usage: --vpn-helper <uid>\n".utf8)); return 2
        }
        signal(SIGPIPE, SIG_IGN)
        let sup = SingBoxSupervisor()
        let path = VPNHelperPaths.socket
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return 1 }
        var addr = sockaddr_un()
        guard IPCServer.fill(&addr, path: path) else { return 1 }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { perror("bind"); return 1 }
        chmod(path, 0o666)
        guard listen(fd, 8) == 0 else { return 1 }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { sup.shutdown(); unlink(path); exit(0) }
        term.resume()

        let acceptQueue = DispatchQueue(label: "safenet.vpn.accept")
        acceptQueue.async {
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { if errno == EINTR { continue }; usleep(100_000); continue }
                _ = fcntl(c, F_SETFD, FD_CLOEXEC)
                var one: Int32 = 1
                _ = setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                var peer: uid_t = 0, gid: gid_t = 0
                guard getpeereid(c, &peer, &gid) == 0, peer == uid || peer == 0 else { close(c); continue }
                DispatchQueue.global().async { serve(c, sup) }
            }
        }
        dispatchMain()
    }

    static func serve(_ fd: Int32, _ sup: SingBoxSupervisor) {
        defer { close(fd) }
        guard case .success(let line) = IPCIO.readLine(fd, timeout: 3) else { return }
        let resp = handle(line, sup)
        guard var out = try? JSONEncoder.vpn.encode(resp) else { return }
        out.append(0x0A)
        _ = IPCIO.write(fd, out, timeout: 3)
        shutdown(fd, SHUT_WR)
    }

    static func handle(_ line: Data, _ sup: SingBoxSupervisor) -> VPNHelperResponse {
        guard let req = try? JSONDecoder.vpn.decode(VPNHelperRequest.self, from: line) else {
            return VPNHelperResponse(ok: false, error: "неверный запрос")
        }
        switch req.cmd {
        case "status": return VPNHelperResponse(ok: true, status: sup.currentStatus())
        case "stop": return VPNHelperResponse(ok: true, status: sup.stop())
        case "start":
            guard let r = req.start else { return VPNHelperResponse(ok: false, error: "нет параметров") }
            switch sup.start(r) {
            case .success(let s): return VPNHelperResponse(ok: true, status: s)
            case .failure(let m): return VPNHelperResponse(ok: false, error: m.description)
            }
        default: return VPNHelperResponse(ok: false, error: "неизвестная команда")
        }
    }
}
