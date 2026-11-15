import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: Trace parsing

/// Parses Cloudflare `/cdn-cgi/trace` (key=value lines). Needs a valid `ip` (inet_pton) and a 2-letter ASCII `loc`.
public func parseTrace(_ text: String) -> (ip: String, loc: String)? {
    var ip: String?, loc: String?
    for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
        guard let eq = line.firstIndex(of: "=") else { continue }
        let k = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
        let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if k == "ip", ip == nil { ip = v } else if k == "loc", loc == nil { loc = v }
    }
    guard let i = ip, HTTPIPService.isValidIP(i), let l = loc,
          l.utf8.count == 2, l.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) })
    else { return nil }
    return (i, l.uppercased())
}

// MARK: Route probe (AI services)

public struct RouteResult: Equatable {
    public var host: String
    public var ip: String?
    public var country: String?
    public var error: String?
    public init(host: String, ip: String?, country: String?, error: String?) {
        self.host = host; self.ip = ip; self.country = country; self.error = error
    }
}

public protocol TraceFetcher {
    /// Returns the (size-capped) body of https://<host>/cdn-cgi/trace.
    func fetch(host: String) async throws -> String
}

public enum RouteProbeError: Error { case badHost, badStatus, badBody, timeout }

/// URLSession-based fetcher: ephemeral session (no cookies/cache), default system proxy handling (PAC out of scope),
/// body capped at 4 KB.
public struct URLSessionTraceFetcher: TraceFetcher {
    public static let hosts = ["api.anthropic.com", "claude.ai", "chatgpt.com", "api.openai.com", "www.perplexity.ai"]
    public static let maxBytes = 4096
    private let session: URLSession
    private let requestTimeout: TimeInterval

    public init(requestTimeout: TimeInterval = 5) {
        self.requestTimeout = requestTimeout
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = requestTimeout
        cfg.timeoutIntervalForResource = requestTimeout
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCredentialStorage = nil
        cfg.httpAdditionalHeaders = ["User-Agent": "SafeNet", "Accept": "text/plain"]
        session = URLSession(configuration: cfg)
    }

    public func fetch(host: String) async throws -> String {
        var c = URLComponents()
        c.scheme = "https"; c.host = host; c.path = "/cdn-cgi/trace"
        guard let url = c.url else { throw RouteProbeError.badHost }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = requestTimeout
        let (bytes, resp) = try await session.bytes(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { throw RouteProbeError.badStatus }
        var data = Data()
        for try await b in bytes {
            data.append(b)
            if data.count >= URLSessionTraceFetcher.maxBytes { break }
        }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct RouteProbe {
    private let fetcher: TraceFetcher
    private let timeout: TimeInterval

    public init(fetcher: TraceFetcher = URLSessionTraceFetcher(), timeout: TimeInterval = 6) {
        self.fetcher = fetcher; self.timeout = timeout
    }

    /// Fetches the trace of every host in parallel. A failing/slow/garbled host yields an error result
    /// (never a clean one). Result order equals `hosts` order.
    public func check(hosts: [String]) async -> [RouteResult] {
        let fetcher = self.fetcher, timeout = self.timeout
        return await withTaskGroup(of: (Int, RouteResult).self) { group in
            for (i, h) in hosts.enumerated() {
                group.addTask { (i, await RouteProbe.probe(host: h, fetcher: fetcher, timeout: timeout)) }
            }
            var all: [(Int, RouteResult)] = []
            for await r in group { all.append(r) }
            return all.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    static func validHost(_ h: String) -> Bool {
        !h.isEmpty && h.utf8.count <= 253 && h.utf8.allSatisfy {
            ($0 >= 97 && $0 <= 122) || ($0 >= 65 && $0 <= 90) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46
        }
    }

    static func probe(host: String, fetcher: TraceFetcher, timeout: TimeInterval) async -> RouteResult {
        guard validHost(host) else { return RouteResult(host: host, ip: nil, country: nil, error: "bad host name") }
        do {
            let body = try await withDeadline(timeout) { try await fetcher.fetch(host: host) }
            guard let t = parseTrace(body) else { return RouteResult(host: host, ip: nil, country: nil, error: "unparseable trace") }
            return RouteResult(host: host, ip: t.ip, country: t.loc, error: nil)
        } catch {
            return RouteResult(host: host, ip: nil, country: nil, error: "\(error)")
        }
    }

    private static func withDeadline<T>(_ seconds: TimeInterval, _ op: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { g in
            g.addTask { try await op() }
            g.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw RouteProbeError.timeout
            }
            defer { g.cancelAll() }
            return try await g.next()!
        }
    }
}

// MARK: Leak decisions (pure)

private func allowed(_ a: IPAnswer, _ allow: AllowList) -> Bool {
    if allow.ips.contains(where: { IPMatcher.matches(a.ip, entry: $0) }) { return true }
    let c = a.country.uppercased()
    return !c.isEmpty && allow.countries.contains { $0.uppercased() == c }
}

/// Route leak: any AI-service trace that came back with an address/country outside the allow list.
/// Hosts that errored are NOT counted as leaks (nothing was learned; the IP check still guards the main path).
public func detectRouteLeak(_ results: [RouteResult], allow: AllowList) -> Bool {
    results.contains { r in
        guard r.error == nil, let ip = r.ip else { return false }
        return !allowed(IPAnswer(ip: ip, country: r.country ?? ""), allow)
    }
}

/// IPv6 leak heuristic: the machine has a global IPv6 address on a physical interface AND some IP service
/// answered over IPv6 with an address outside the allow list. (Whether the IPv4 answer is allowed does not matter:
/// a disallowed v6 path is a leak in every case.) No v6 answer, or no global v6 address, is never a leak.
public func detectIPv6Leak(hasGlobalIPv6: Bool, answers: [IPAnswer], allow: AllowList) -> Bool {
    guard hasGlobalIPv6 else { return false }
    return answers.contains { $0.ip.contains(":") && !allowed($0, allow) }
}

// MARK: DNS

public struct DNSResolver: Equatable {
    public var address: String
    public var interface: String?
    /// From the "for scoped queries" section: bound to one interface, not the default resolver.
    public var scoped: Bool
    public init(address: String, interface: String?, scoped: Bool) {
        self.address = address; self.interface = interface; self.scoped = scoped
    }
}

/// Parses `scutil --dns`. Nameserver zone suffixes (`fe80::1%en0`) are stripped; invalid addresses are dropped.
public func parseScutilDNS(_ output: String) -> [DNSResolver] {
    var res: [DNSResolver] = []
    var scoped = false
    var addrs: [String] = [], iface: String?
    func flush() {
        for a in addrs { res.append(DNSResolver(address: a, interface: iface, scoped: scoped)) }
        addrs = []; iface = nil
    }
    for raw in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("DNS configuration") { flush(); scoped = line.contains("scoped"); continue }
        if line.hasPrefix("resolver #") { flush(); continue }
        guard let colon = line.firstIndex(of: ":") else { continue }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if key.hasPrefix("nameserver[") {
            let a = String(val.split(separator: "%", maxSplits: 1).first ?? "")
            if HTTPIPService.isValidIP(a) { addrs.append(a) }
        } else if key == "if_index", let o = val.firstIndex(of: "("), let c = val.firstIndex(of: ")"), o < c {
            iface = String(val[val.index(after: o)..<c])
        }
    }
    flush()
    return res
}

func isTunnelInterface(_ n: String) -> Bool {
    ["utun", "ppp", "ipsec", "tun", "tap", "wg"].contains { n.hasPrefix($0) }
}

func isPublicAddress(_ ip: String) -> Bool {
    let nonPublic = ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
                     "192.168.0.0/16", "::/128", "::1/128", "fc00::/7", "fe80::/10"]
    return IPMatcher.parse(ip) != nil && !nonPublic.contains { IPMatcher.matches(ip, entry: $0) }
}

/// DNS leak heuristic (conservative; the default mode only warns). Only meaningful while a tunnel exists.
/// "Physical DNS" = resolvers bound (scoped, or by if_index) to a non-tunnel interface, i.e. the DHCP/router DNS.
/// For each DEFAULT (non-scoped) resolver:
///  - loopback/link-local/unspecified/198.18.0.0/15 (benchmark range used by fake-ip DNS of proxy tools) -> fine;
///  - bound to a tunnel interface -> fine;
///  - address equals a physical DNS -> LEAK (the system still asks the ISP/router resolver outside the VPN);
///  - public address bound to a non-tunnel interface -> LEAK;
///  - anything else (private, unknown interface, not a physical DNS) -> fine. We cannot tell, so we do not accuse.
/// Known false positives: split-DNS corporate VPNs that intentionally keep the LAN resolver as default.
public func detectDNSLeak(resolvers: [DNSResolver], hasTunnel: Bool) -> Bool {
    guard hasTunnel else { return false }
    let physical = Set(resolvers.filter { r in r.interface.map { !isTunnelInterface($0) } ?? false }.map { $0.address })
    for r in resolvers where !r.scoped {
        if let i = r.interface, isTunnelInterface(i) { continue }
        if IPMatcher.matches(r.address, entry: "127.0.0.0/8") || IPMatcher.matches(r.address, entry: "::1/128")
            || IPMatcher.matches(r.address, entry: "fe80::/10") || IPMatcher.matches(r.address, entry: "169.254.0.0/16")
            || IPMatcher.matches(r.address, entry: "::/128") || IPMatcher.matches(r.address, entry: "0.0.0.0/8")
            || IPMatcher.matches(r.address, entry: "198.18.0.0/15") { continue }   // fake-ip DNS of local proxy/VPN tools
        if physical.contains(r.address) { return true }
        if r.interface != nil, isPublicAddress(r.address) { return true }
    }
    return false
}

// MARK: Sampler

public enum NetworkSampler {
    /// Pure mapping of everything measured in one cycle to the guard's `Observation`.
    /// `allow` is the effective allow list (the caller picks the common or a per-app one).
    public static func makeObservation(snapshot: NetSnapshot, answers: [IPAnswer], routes: [RouteResult],
                                       resolvers: [DNSResolver], allow: AllowList, config: Config) -> Observation {
        Observation(
            online: snapshot.online,
            ips: answers,
            ipv6Leak: config.checkIPv6 && detectIPv6Leak(hasGlobalIPv6: snapshot.hasGlobalIPv6, answers: answers, allow: allow),
            dnsLeak: config.dnsCheck != .off && detectDNSLeak(resolvers: resolvers, hasTunnel: snapshot.hasTunnel),
            routeLeak: config.routeCheck && detectRouteLeak(routes, allow: allow),
            trustedNetwork: isTrusted(snapshot, config.trustedNetworks))
    }
}
