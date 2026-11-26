import Foundation

/// What goes through the tunnel.
public enum VPNMode: String, Codable, Equatable, CaseIterable {
    /// Everything (local networks excepted). If the server is unreachable nothing gets out.
    case all
    /// Only the protected apps; the rest of the Mac goes directly.
    case apps
}

/// What the app asks the root helper to run. The helper never takes a ready-made sing-box config:
/// it builds one from this (`SingBoxConfig.build`), after `validate`.
public struct VPNStartRequest: Codable, Equatable {
    public var outbound: JSONValue
    public var mode: VPNMode
    /// Executable path fragments of the protected apps ("/Claude.app/"), for `.apps`.
    public var appPaths: [String]
    /// Executable names ("node", "claude"), for `.apps`.
    public var appNames: [String]
    public init(outbound: JSONValue, mode: VPNMode, appPaths: [String] = [], appNames: [String] = []) {
        self.outbound = outbound; self.mode = mode; self.appPaths = appPaths; self.appNames = appNames
    }
}

public enum SingBoxConfig {
    public static let outboundTypes: Set<String> = ["vless", "vmess", "trojan", "shadowsocks", "hysteria2", "tuic"]
    /// Addresses of the tunnel interface (IPv6 too: otherwise IPv6 would go around the tunnel).
    public static let tunAddresses: [JSONValue] = ["172.19.0.1/30", "fdfe:dcba:9876::1/126"]
    public static let remoteDNS = "1.1.1.1"

    /// The helper runs sing-box as root, so the request must not be able to name files or chain
    /// outbounds: only the six proxy types, tag "proxy", no `*_path` / `path`-to-file keys, no
    /// `detour`, sane sizes. The transport's URL `path` is allowed.
    public static func validate(_ r: VPNStartRequest) throws {
        guard let o = r.outbound.object else { throw ProxyLinkError("сервер описан неверно") }
        guard let type = o["type"]?.string, outboundTypes.contains(type) else { throw ProxyLinkError("тип сервера не поддерживается") }
        guard o["tag"]?.string == "proxy" else { throw ProxyLinkError("сервер описан неверно (tag)") }
        guard let server = o["server"]?.string, !server.isEmpty, server.utf8.count <= 253 else { throw ProxyLinkError("нет адреса сервера") }
        try check(r.outbound, path: [])
        guard r.appPaths.count <= 200, r.appNames.count <= 200 else { throw ProxyLinkError("слишком много приложений") }
        for s in r.appPaths + r.appNames {
            guard !s.isEmpty, s.utf8.count <= 300, !s.contains("\0"), !s.contains("\n") else { throw ProxyLinkError("неверное имя приложения") }
        }
        if r.mode == .apps, r.appPaths.isEmpty, r.appNames.isEmpty {
            throw ProxyLinkError("режим «только защищаемые приложения», но приложения не выбраны")
        }
        guard r.outbound.encoded().count <= 16_384 else { throw ProxyLinkError("описание сервера слишком большое") }
    }

    private static func check(_ v: JSONValue, path: [String]) throws {
        switch v {
        case .object(let o):
            for (k, x) in o {
                let lower = k.lowercased()
                let inTransport = path.last == "transport"
                if lower.hasSuffix("_path") || lower == "detour" || lower == "domain_resolver" || lower == "dial_fields"
                    || (lower == "path" && !inTransport) || lower == "certificate" || lower == "key" && path.last == "tls" {
                    throw ProxyLinkError("поле \(k) в описании сервера не разрешено")
                }
                try check(x, path: path + [k])
            }
        case .array(let a): for x in a { try check(x, path: path) }
        case .string(let s): if s.contains("\0") || s.utf8.count > 4096 { throw ProxyLinkError("неверное значение в описании сервера") }
        default: break
        }
    }

    /// Go regexp for an executable path fragment ("/Claude.app/" -> "/Claude\.app/").
    public static func regex(forFragment f: String) -> String {
        var out = ""
        for ch in f {
            if "\\.^$|?*+()[]{}".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// The full sing-box config. Kill switch by construction: `strict_route` keeps everything on
    /// the tunnel, and in `.all` the final outbound is the proxy, so with the server down nothing
    /// leaks (connections fail). DNS goes through the proxy too (DNS over HTTPS to 1.1.1.1).
    public static func build(_ r: VPNStartRequest) -> JSONValue {
        let paths: [JSONValue] = r.appPaths.map { .string(regex(forFragment: $0)) }
        let names: [JSONValue] = r.appNames.map { .string($0) }
        var appRules: [JSONValue] = []
        if !paths.isEmpty { appRules.append(["process_path_regex": .array(paths), "outbound": "proxy"]) }
        if !names.isEmpty { appRules.append(["process_name": .array(names), "outbound": "proxy"]) }
        var dnsRules: [JSONValue] = []
        if r.mode == .apps {
            if !paths.isEmpty { dnsRules.append(["process_path_regex": .array(paths), "server": "remote"]) }
            if !names.isEmpty { dnsRules.append(["process_name": .array(names), "server": "remote"]) }
        }
        let rules: [JSONValue] = [
            ["action": "sniff"],
            ["protocol": "dns", "action": "hijack-dns"],
            ["ip_is_private": true, "outbound": "direct"],
        ] + (r.mode == .apps ? appRules : [])
        var dns: [String: JSONValue] = [
            "servers": [
                ["type": "https", "tag": "remote", "server": .string(remoteDNS), "detour": "proxy"],
                ["type": "local", "tag": "local"],
            ],
            "final": r.mode == .all ? "remote" : "local",
            "strategy": "ipv4_only",
        ]
        if !dnsRules.isEmpty { dns["rules"] = .array(dnsRules) }
        return [
            "log": ["level": "warn", "timestamp": true],
            "dns": .object(dns),
            "inbounds": [[
                "type": "tun", "tag": "tun-in", "address": .array(tunAddresses), "mtu": 1500,
                "auto_route": true, "strict_route": true, "stack": "mixed",
            ]],
            "outbounds": [r.outbound, ["type": "direct", "tag": "direct"]],
            "route": [
                "rules": .array(rules),
                "final": r.mode == .all ? "proxy" : "direct",
                "auto_detect_interface": true,
                "default_domain_resolver": "local",
            ],
        ]
    }

    /// Path fragments and names the tunnel uses for the protected apps (`.apps` mode), from the
    /// same matchers the freezer uses: "/X.app/" fragments; "node && …" -> node; "cmd:claude" ->
    /// claude. Other matcher kinds cannot be expressed as routing rules and are left out.
    public static func appSelectors(_ matches: [String]) -> (paths: [String], names: [String]) {
        var paths: [String] = [], names: [String] = []
        for m in matches {
            for part in m.components(separatedBy: "&&").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                if part.hasPrefix("args:") { continue }
                if part.hasPrefix("cmd:") {
                    let n = String(part.dropFirst(4)); if !n.isEmpty, !names.contains(n) { names.append(n) }
                } else if part.contains("/") {
                    if !paths.contains(part) { paths.append(part) }
                } else if !part.isEmpty, !names.contains(part) {
                    names.append(part)
                }
            }
        }
        return (paths, names)
    }
}
