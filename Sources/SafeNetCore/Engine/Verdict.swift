import Foundation

public enum Reason: Equatable {
    case ipNotAllowed, countryNotAllowed, unconfirmed, ipv6Leak, dnsLeak, routeLeak, networkChanged
    /// Produced only by `Guard` (frozen because there is no network; never closes).
    case offline
}

public enum Verdict: Equatable {
    case ok
    case freeze(Reason)
    /// No network. Apps are frozen (when configured) but NEVER closed because of this.
    case offline
}

public struct IPAnswer: Equatable {
    public var ip: String
    public var country: String
    public init(ip: String, country: String) { self.ip = ip; self.country = country }
}

public struct Observation: Equatable {
    public var online: Bool
    public var ips: [IPAnswer]
    public var ipv6Leak: Bool
    public var dnsLeak: Bool
    public var routeLeak: Bool
    public var trustedNetwork: Bool
    public init(online: Bool, ips: [IPAnswer], ipv6Leak: Bool, dnsLeak: Bool, routeLeak: Bool, trustedNetwork: Bool) {
        self.online = online; self.ips = ips; self.ipv6Leak = ipv6Leak
        self.dnsLeak = dnsLeak; self.routeLeak = routeLeak; self.trustedNetwork = trustedNetwork
    }
}

/// Per-app rules REPLACE (not extend) the common allow list.
public func effectiveAllow(for app: String, in config: Config) -> AllowList {
    config.appRules[app] ?? config.allow
}

/// Pure policy. Evaluation order (first match wins; any uncertainty = freeze):
///  1. offline            -> .offline (checked before everything, trusted network included: no link, nothing to trust)
///  2. trusted network    -> .ok (online on a known network: VPN not required, leak/IP checks skipped)
///  3. ipv6 / route leak  -> freeze (always); dns leak -> freeze only in .block mode (.warn/.off never freeze here)
///  4. confirmation       -> need >= minAgree answers with identical IP AND country (minAgree < 1 is treated as 1);
///                           none, or several different groups reaching quorum -> .unconfirmed
///  5. allow list         -> IP matches an exact/CIDR entry OR country is in the list; otherwise freeze.
///                           An EMPTY allow list allows nothing (fail closed).
public func evaluate(_ o: Observation, allow: AllowList, minAgree: Int, dnsCheck: DNSCheckMode) -> Verdict {
    guard o.online else { return .offline }
    if o.trustedNetwork { return .ok }
    if o.ipv6Leak { return .freeze(.ipv6Leak) }
    if o.routeLeak { return .freeze(.routeLeak) }
    if o.dnsLeak && dnsCheck == .block { return .freeze(.dnsLeak) }

    let quorum = max(1, minAgree)
    var groups: [String: (answer: IPAnswer, count: Int)] = [:]
    for a in o.ips {
        let key = a.ip + "|" + a.country.uppercased()
        groups[key, default: (a, 0)].count += 1
    }
    let confirmed = groups.values.filter { $0.count >= quorum }
    guard confirmed.count == 1, let answer = confirmed.first?.answer else { return .freeze(.unconfirmed) }

    if allow.ips.contains(where: { IPMatcher.matches(answer.ip, entry: $0) }) { return .ok }
    let country = answer.country.uppercased()
    if allow.countries.contains(where: { $0.uppercased() == country && !country.isEmpty }) { return .ok }
    return .freeze(allow.ips.isEmpty && !allow.countries.isEmpty ? .countryNotAllowed : .ipNotAllowed)
}

/// Exact-IP / CIDR matching for IPv4 and IPv6. Anything malformed never matches.
enum IPMatcher {
    static func matches(_ ip: String, entry: String) -> Bool {
        guard let addr = parse(ip) else { return false }
        let parts = entry.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let net = parse(parts[0]), net.count == addr.count else { return false }
        var prefix = net.count * 8
        if parts.count == 2 {
            let p = parts[1]
            guard !p.isEmpty, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p), n <= net.count * 8 else { return false }
            prefix = n
        }
        var bits = prefix
        for i in 0..<net.count {
            if bits <= 0 { break }
            let mask: UInt8 = bits >= 8 ? 0xFF : UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
            if (addr[i] & mask) != (net[i] & mask) { return false }
            bits -= 8
        }
        return true
    }

    static func parse(_ s: String) -> [UInt8]? {
        if s.isEmpty || s.count > 45 { return nil }
        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, s, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }
}
