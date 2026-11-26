import Foundation
import CryptoKit

/// One server the user can connect to: parsed from a share link (vless://, vmess://, trojan://,
/// ss://, hysteria2:// / hy2://, tuic://). `outbound` is the sing-box outbound (tag "proxy").
public struct VPNProfile: Equatable {
    /// The link exactly as given (stored; profiles are re-parsed from it).
    public var link: String
    public var name: String
    /// vless, vmess, trojan, shadowsocks, hysteria2, tuic.
    public var kind: String
    public var server: String
    public var port: Int
    public var outbound: JSONValue

    /// Stable id: SHA-256 of the link (prefix). Survives subscription refreshes when the link stays.
    public var id: String { VPNProfile.id(of: link) }
    public static func id(of link: String) -> String {
        SHA256.hash(data: Data(link.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// "VLESS · nl.example.com:443"
    public var summary: String { "\(VPNProfile.kindName(kind)) · \(server):\(port)" }

    public static func kindName(_ k: String) -> String {
        switch k {
        case "vless": return "VLESS"
        case "vmess": return "VMess"
        case "trojan": return "Trojan"
        case "shadowsocks": return "Shadowsocks"
        case "hysteria2": return "Hysteria2"
        case "tuic": return "TUIC"
        default: return k
        }
    }
}

public struct ProxyLinkError: Error, Equatable, CustomStringConvertible {
    public var description: String
    public init(_ d: String) { description = d }
}

public enum ProxyLink {
    public static let schemes = ["vless", "vmess", "trojan", "ss", "hysteria2", "hy2", "tuic"]

    /// True when the line looks like a share link of a supported scheme.
    public static func looksLikeLink(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return schemes.contains { t.hasPrefix($0 + "://") }
    }

    public static func parse(_ raw: String) throws -> VPNProfile {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sep = link.range(of: "://") else { throw ProxyLinkError("это не ссылка на сервер") }
        let scheme = link[..<sep.lowerBound].lowercased()
        switch scheme {
        case "vless": return try vless(link)
        case "vmess": return try vmess(link)
        case "trojan": return try trojan(link)
        case "ss": return try shadowsocks(link)
        case "hysteria2", "hy2": return try hysteria2(link)
        case "tuic": return try tuic(link)
        case "happ", "v2raytun", "hiddify", "streisand", "sing-box", "clash":
            throw ProxyLinkError("это ссылка-приглашение другого приложения; возьмите у провайдера ссылку подписки (https://…) или ссылку на сервер (vless://…)")
        default:
            throw ProxyLinkError("протокол \(scheme) не поддерживается")
        }
    }

    // MARK: Pieces

    struct Parts {
        var user: String
        var password: String?
        var host: String
        var port: Int
        var query: [String: String]
        var name: String
    }

    /// scheme://user[:password]@host:port?query#name (host may be [IPv6]).
    static func parts(_ link: String, defaultName: String) throws -> Parts {
        guard let c = URLComponents(string: link) else { throw ProxyLinkError("ссылка повреждена") }
        guard let host = c.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), !host.isEmpty else {
            throw ProxyLinkError("в ссылке нет адреса сервера")
        }
        guard let port = c.port, (1...65535).contains(port) else { throw ProxyLinkError("в ссылке нет порта сервера") }
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] where q[item.name] == nil { q[item.name] = item.value ?? "" }
        let user = (c.percentEncodedUser ?? "").removingPercentEncoding ?? ""
        let pass = c.percentEncodedPassword.map { $0.removingPercentEncoding ?? $0 }
        let frag = (c.percentEncodedFragment ?? "").removingPercentEncoding ?? ""
        let name = frag.trimmingCharacters(in: .whitespacesAndNewlines)
        return Parts(user: user, password: pass, host: host, port: port, query: q, name: name.isEmpty ? defaultName : name)
    }

    static func base64Decoded(_ s: String) -> Data? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        t = t.filter { !$0.isWhitespace }
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    static func truthy(_ v: String?) -> Bool { ["1", "true", "yes"].contains((v ?? "").lowercased()) }

    static func list(_ v: String?) -> [JSONValue] {
        (v ?? "").split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 != .string("") }
    }

    /// TLS block from the usual query keys (security, sni, fp, alpn, pbk, sid, allowInsecure).
    static func tls(_ q: [String: String], host: String, security: String?) throws -> JSONValue? {
        let sec = (security ?? q["security"] ?? "").lowercased()
        guard sec == "tls" || sec == "reality" || sec == "xtls" else {
            if !sec.isEmpty, sec != "none" { throw ProxyLinkError("шифрование \(sec) не поддерживается") }
            return nil
        }
        var t: [String: JSONValue] = ["enabled": true]
        let sni = q["sni"] ?? q["peer"] ?? q["host"] ?? ""
        t["server_name"] = .string(sni.isEmpty ? host : sni)
        if truthy(q["allowInsecure"]) || truthy(q["insecure"]) || truthy(q["allow_insecure"]) { t["insecure"] = true }
        let alpn = list(q["alpn"])
        if !alpn.isEmpty { t["alpn"] = .array(alpn) }
        let fp = (q["fp"] ?? "").lowercased()
        if sec == "reality" {
            guard let pbk = q["pbk"], !pbk.isEmpty else { throw ProxyLinkError("для Reality в ссылке нужен ключ pbk") }
            t["reality"] = ["enabled": true, "public_key": .string(pbk), "short_id": .string(q["sid"] ?? "")]
            t["utls"] = ["enabled": true, "fingerprint": .string(fp.isEmpty || fp == "random" ? "chrome" : fp)]
        } else if !fp.isEmpty {
            t["utls"] = ["enabled": true, "fingerprint": .string(fp == "random" ? "chrome" : fp)]
        }
        return .object(t)
    }

    /// Transport from `type` (tcp, ws, grpc, http/h2, httpupgrade). nil = plain TCP.
    static func transport(_ q: [String: String]) throws -> JSONValue? {
        let type = (q["type"] ?? q["net"] ?? "tcp").lowercased()
        let path = q["path"].map { $0.isEmpty ? "/" : $0 } ?? "/"
        let host = q["host"] ?? ""
        switch type {
        case "tcp", "":
            if (q["headerType"] ?? "none").lowercased() == "http" {
                var t: [String: JSONValue] = ["type": "http", "method": "GET", "path": .string(path)]
                if !host.isEmpty { t["host"] = .array(list(host)) }
                return .object(t)
            }
            return nil
        case "ws", "websocket":
            var t: [String: JSONValue] = ["type": "ws", "path": .string(path)]
            if !host.isEmpty { t["headers"] = ["Host": .string(host)] }
            if let ed = q["ed"], let n = Int(ed), n > 0 {
                t["max_early_data"] = .number(Double(n)); t["early_data_header_name"] = "Sec-WebSocket-Protocol"
            }
            return .object(t)
        case "grpc":
            return ["type": "grpc", "service_name": .string(q["serviceName"] ?? q["path"] ?? "")]
        case "http", "h2":
            var t: [String: JSONValue] = ["type": "http", "path": .string(path)]
            if !host.isEmpty { t["host"] = .array(list(host)) }
            return .object(t)
        case "httpupgrade":
            var t: [String: JSONValue] = ["type": "httpupgrade", "path": .string(path)]
            if !host.isEmpty { t["host"] = .string(host) }
            return .object(t)
        case "xhttp", "splithttp":
            throw ProxyLinkError("транспорт XHTTP не поддерживается ядром sing-box; попросите у провайдера сервер с TCP, WS или gRPC")
        case "kcp", "quic":
            throw ProxyLinkError("транспорт \(type) не поддерживается")
        default:
            throw ProxyLinkError("транспорт \(type) не поддерживается")
        }
    }

    static func base(_ type: String, _ p: Parts) -> [String: JSONValue] {
        ["type": .string(type), "tag": "proxy", "server": .string(p.host), "server_port": .number(Double(p.port))]
    }

    static func profile(_ link: String, _ kind: String, _ p: Parts, _ o: [String: JSONValue]) -> VPNProfile {
        VPNProfile(link: link, name: p.name, kind: kind, server: p.host, port: p.port, outbound: .object(o))
    }

    // MARK: Protocols

    static func vless(_ link: String) throws -> VPNProfile {
        let p = try parts(link, defaultName: "VLESS")
        guard UUID(uuidString: p.user) != nil || !p.user.isEmpty else { throw ProxyLinkError("в ссылке нет UUID") }
        var o = base("vless", p)
        o["uuid"] = .string(p.user)
        if let flow = p.query["flow"], !flow.isEmpty {
            guard flow.hasPrefix("xtls-rprx-vision") else { throw ProxyLinkError("flow \(flow) не поддерживается") }
            o["flow"] = "xtls-rprx-vision"
        }
        o["packet_encoding"] = "xudp"
        if let t = try tls(p.query, host: p.host, security: nil) { o["tls"] = t }
        if let tr = try transport(p.query) { o["transport"] = tr }
        return profile(link, "vless", p, o)
    }

    static func trojan(_ link: String) throws -> VPNProfile {
        let p = try parts(link, defaultName: "Trojan")
        guard !p.user.isEmpty else { throw ProxyLinkError("в ссылке нет пароля") }
        var o = base("trojan", p)
        o["password"] = .string(p.user)
        // Trojan is TLS by definition: security=none is the only way to turn it off.
        let sec = (p.query["security"] ?? "tls").lowercased()
        if let t = try tls(p.query, host: p.host, security: sec.isEmpty ? "tls" : sec) { o["tls"] = t }
        if let tr = try transport(p.query) { o["transport"] = tr }
        return profile(link, "trojan", p, o)
    }

    static func vmess(_ link: String) throws -> VPNProfile {
        let body = String(link.dropFirst("vmess://".count)).components(separatedBy: "#")[0]
        guard let data = base64Decoded(body),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProxyLinkError("ссылка VMess повреждена")
        }
        func s(_ k: String) -> String {
            if let v = obj[k] as? String { return v.trimmingCharacters(in: .whitespaces) }
            if let v = obj[k] as? NSNumber { return v.stringValue }
            return ""
        }
        guard let port = Int(s("port")), (1...65535).contains(port), !s("add").isEmpty, !s("id").isEmpty else {
            throw ProxyLinkError("в ссылке VMess нет адреса, порта или UUID")
        }
        let name = s("ps").isEmpty ? "VMess" : s("ps")
        let p = Parts(user: s("id"), password: nil, host: s("add"), port: port, query: [:], name: name)
        var o = base("vmess", p)
        o["uuid"] = .string(s("id"))
        o["security"] = .string(s("scy").isEmpty ? "auto" : s("scy"))
        o["alter_id"] = .number(Double(Int(s("aid")) ?? 0))
        o["packet_encoding"] = "xudp"
        var q: [String: String] = ["type": s("net").isEmpty ? "tcp" : s("net"), "host": s("host"), "path": s("path"),
                                   "sni": s("sni"), "alpn": s("alpn"), "fp": s("fp"), "headerType": s("type")]
        if s("net") == "grpc" { q["serviceName"] = s("path") }
        if q["path"] == "" { q["path"] = nil }
        let sec = s("tls").lowercased()
        if let t = try tls(q, host: s("add"), security: sec == "tls" ? "tls" : (sec.isEmpty ? "none" : sec)) { o["tls"] = t }
        if let tr = try transport(q) { o["transport"] = tr }
        return profile(link, "vmess", p, o)
    }

    static let ssMethods: Set<String> = [
        "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305",
        "aes-128-gcm", "aes-192-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305", "none",
    ]

    /// SIP002 (ss://base64(method:password)@host:port#name, or the userinfo url-encoded) and the
    /// legacy form ss://base64(method:password@host:port)#name.
    static func shadowsocks(_ link: String) throws -> VPNProfile {
        var work = link
        let body = String(link.dropFirst("ss://".count))
        if !body.contains("@") {
            let main = body.components(separatedBy: "#")[0].components(separatedBy: "?")[0]
            let rest = String(body.dropFirst(main.count))
            guard let d = base64Decoded(main), let decoded = String(data: d, encoding: .utf8) else {
                throw ProxyLinkError("ссылка Shadowsocks повреждена")
            }
            guard let at = decoded.lastIndex(of: "@") else { throw ProxyLinkError("ссылка Shadowsocks повреждена") }
            let cred = Data(decoded[..<at].utf8).base64EncodedString()
            work = "ss://" + cred + "@" + decoded[decoded.index(after: at)...] + rest
        }
        let p = try parts(work, defaultName: "Shadowsocks")
        if let plugin = p.query["plugin"], !plugin.isEmpty { throw ProxyLinkError("плагины Shadowsocks (\(plugin.components(separatedBy: ";")[0])) не поддерживаются") }
        var method = "", password = ""
        if let pw = p.password, !pw.isEmpty {
            method = p.user; password = pw
        } else if let d = base64Decoded(p.user), let s = String(data: d, encoding: .utf8), let colon = s.firstIndex(of: ":") {
            method = String(s[..<colon]); password = String(s[s.index(after: colon)...])
        } else {
            throw ProxyLinkError("в ссылке Shadowsocks нет метода и пароля")
        }
        method = method.lowercased()
        guard ssMethods.contains(method) else { throw ProxyLinkError("шифр \(method) не поддерживается") }
        var o = base("shadowsocks", p)
        o["method"] = .string(method)
        o["password"] = .string(password)
        return profile(link, "shadowsocks", p, o)
    }

    static func hysteria2(_ link: String) throws -> VPNProfile {
        let p = try parts(link, defaultName: "Hysteria2")
        var o = base("hysteria2", p)
        let auth = p.password.map { p.user + ":" + $0 } ?? p.user
        if !auth.isEmpty { o["password"] = .string(auth) }
        if let obfs = p.query["obfs"], !obfs.isEmpty {
            guard obfs == "salamander" else { throw ProxyLinkError("обфускация \(obfs) не поддерживается") }
            o["obfs"] = ["type": "salamander", "password": .string(p.query["obfs-password"] ?? "")]
        }
        if let ports = p.query["mport"], !ports.isEmpty {
            o["server_ports"] = .array(ports.split(separator: ",").map { .string($0.replacingOccurrences(of: "-", with: ":")) })
        }
        var t: [String: JSONValue] = ["enabled": true, "server_name": .string((p.query["sni"] ?? "").isEmpty ? p.host : p.query["sni"]!)]
        if truthy(p.query["insecure"]) { t["insecure"] = true }
        let alpn = list(p.query["alpn"])
        t["alpn"] = alpn.isEmpty ? ["h3"] : .array(alpn)
        o["tls"] = .object(t)
        return profile(link, "hysteria2", p, o)
    }

    static func tuic(_ link: String) throws -> VPNProfile {
        let p = try parts(link, defaultName: "TUIC")
        guard !p.user.isEmpty, let pw = p.password else { throw ProxyLinkError("в ссылке TUIC нет UUID и пароля") }
        var o = base("tuic", p)
        o["uuid"] = .string(p.user)
        o["password"] = .string(pw)
        o["congestion_control"] = .string(p.query["congestion_control"] ?? "bbr")
        if let mode = p.query["udp_relay_mode"], !mode.isEmpty { o["udp_relay_mode"] = .string(mode) }
        var t: [String: JSONValue] = ["enabled": true, "server_name": .string((p.query["sni"] ?? "").isEmpty ? p.host : p.query["sni"]!)]
        if truthy(p.query["allow_insecure"]) || truthy(p.query["insecure"]) { t["insecure"] = true }
        let alpn = list(p.query["alpn"])
        t["alpn"] = alpn.isEmpty ? ["h3"] : .array(alpn)
        o["tls"] = .object(t)
        return profile(link, "tuic", p, o)
    }
}

// MARK: - Subscriptions

/// What a subscription answered: its servers (unparseable lines are counted, not fatal) and the
/// optional `profile-title` / `subscription-userinfo` headers.
public struct SubscriptionContent: Equatable {
    public var profiles: [VPNProfile]
    public var skipped: [String]
    public var title: String?
    public var info: SubscriptionInfo?
}

public struct SubscriptionInfo: Equatable, Codable {
    public var upload: Int64?
    public var download: Int64?
    public var total: Int64?
    public var expire: Date?
    public init(upload: Int64? = nil, download: Int64? = nil, total: Int64? = nil, expire: Date? = nil) {
        self.upload = upload; self.download = download; self.total = total; self.expire = expire
    }

    /// "upload=1; download=2; total=3; expire=1700000000"
    public static func parse(_ header: String?) -> SubscriptionInfo? {
        guard let h = header, !h.isEmpty else { return nil }
        var i = SubscriptionInfo()
        for part in h.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, let n = Int64(kv[1]) else { continue }
            switch kv[0].lowercased() {
            case "upload": i.upload = n
            case "download": i.download = n
            case "total": i.total = n > 0 ? n : nil
            case "expire": i.expire = n > 0 ? Date(timeIntervalSince1970: TimeInterval(n)) : nil
            default: break
            }
        }
        return i == SubscriptionInfo() ? nil : i
    }
}

public enum Subscription {
    /// Body: base64 of newline-separated links, or the links as plain text.
    public static func decode(_ data: Data, titleHeader: String? = nil, userinfoHeader: String? = nil) throws -> SubscriptionContent {
        var text = String(decoding: data, as: UTF8.self)
        if !text.contains("://"), let d = ProxyLink.base64Decoded(text), let s = String(data: d, encoding: .utf8) { text = s }
        if text.trimmingCharacters(in: .whitespaces).hasPrefix("{") || text.contains("proxies:") {
            throw ProxyLinkError("подписка отдала конфиг Clash/sing-box, а не список ссылок; возьмите у провайдера ссылку для v2rayN/v2RayTun")
        }
        var profiles: [VPNProfile] = [], skipped: [String] = []
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, !l.hasPrefix("#") else { continue }
            do { profiles.append(try ProxyLink.parse(l)) } catch { skipped.append("\(l.prefix(12))…: \(error)") }
        }
        guard !profiles.isEmpty else {
            throw ProxyLinkError(skipped.isEmpty ? "в подписке нет серверов" : "ни один сервер подписки не поддерживается: \(skipped[0])")
        }
        return SubscriptionContent(profiles: profiles, skipped: skipped, title: decodeTitle(titleHeader),
                                   info: SubscriptionInfo.parse(userinfoHeader))
    }

    /// `profile-title`: plain or "base64:…".
    static func decodeTitle(_ h: String?) -> String? {
        guard let h = h?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        if h.hasPrefix("base64:"), let d = ProxyLink.base64Decoded(String(h.dropFirst(7))) {
            return String(data: d, encoding: .utf8)
        }
        return h
    }
}
