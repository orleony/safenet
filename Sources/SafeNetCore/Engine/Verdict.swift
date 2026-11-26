import Foundation

public enum Reason: Equatable {
    case ipNotAllowed, countryNotAllowed, unconfirmed, ipv6Leak, dnsLeak, routeLeak, networkChanged
    /// SafeNet's own VPN is switched on but its tunnel is not up (kill switch).
    case vpnDown
    /// Produced only by `Guard` (frozen because there is no network; never closes).
    case offline
    /// Produced only by `Guard`: the app should be frozen but its processes could not be stopped
    /// (journal not writable, SIGSTOP failed). It is running unrestricted; the countdown still runs.
    case freezeFailed
    /// The app's effective allow list is empty (first run): frozen, but never closed for this.
    case noAllowList
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

/// Raw data for the route / IPv6 leak decisions, judged PER APP against that app's effective
/// allow list (per-app rules replace the common list, also for leaks).
public struct LeakInputs: Equatable {
    /// IPv6 answers of the IP services.
    public var ipv6Answers: [IPAnswer]
    /// Route probe results; nil = not evaluated (see `detectRouteLeak`).
    public var routes: [RouteResult]?
    public var checkIPv6: Bool
    public var checkRoutes: Bool
    public var freshRoutesPending: Bool
    public init(ipv6Answers: [IPAnswer], routes: [RouteResult]?, checkIPv6: Bool, checkRoutes: Bool) {
        self.ipv6Answers = ipv6Answers; self.routes = routes; self.checkIPv6 = checkIPv6; self.checkRoutes = checkRoutes
        self.freshRoutesPending = false
    }
}

public struct Observation: Equatable {
    public var online: Bool
    public var ips: [IPAnswer]
    /// Display / journal flags (some app sees a leak). When `leakInputs` is set, `evaluate`
    /// ignores these two and decides from the raw data with the app's own allow list.
    public var ipv6Leak: Bool
    public var dnsLeak: Bool
    public var routeLeak: Bool
    public var trustedNetwork: Bool
    public var leakInputs: LeakInputs?
    /// SafeNet's built-in VPN is on but its tunnel is down.
    public var vpnDown = false
    public init(online: Bool, ips: [IPAnswer], ipv6Leak: Bool, dnsLeak: Bool, routeLeak: Bool, trustedNetwork: Bool,
                leakInputs: LeakInputs? = nil) {
        self.online = online; self.ips = ips; self.ipv6Leak = ipv6Leak
        self.dnsLeak = dnsLeak; self.routeLeak = routeLeak; self.trustedNetwork = trustedNetwork
        self.leakInputs = leakInputs
    }
}

/// Per-app rules REPLACE (not extend) the common allow list.
public func effectiveAllow(for app: String, in config: Config) -> AllowList {
    config.appRules[app] ?? config.allow
}

/// Multiple exit IPs can establish a country, but cannot establish a single address.
public func sharedExitCountry(_ answers: [IPAnswer], minAgree: Int) -> String? {
    guard answers.count >= max(2, minAgree), let first = answers.first,
          Set(answers.map(\.ip)).count > 1 else { return nil }
    let country = first.country.uppercased()
    guard country.utf8.count == 2, country.utf8.allSatisfy({ (65...90).contains($0) }),
          answers.allSatisfy({ $0.country.uppercased() == country && HTTPIPService.isValidIP($0.ip) })
    else { return nil }
    return country
}

/// Pure policy. Evaluation order (first match wins; any uncertainty = freeze):
///  1. offline            -> .offline (checked before everything, trusted network included: no link, nothing to trust)
///  2. trusted network    -> .ok (online on a known network: VPN not required, leak/IP checks skipped)
///     built-in VPN down  -> freeze(.vpnDown) (switched on in SafeNet, tunnel not up)
///     empty allow list   -> freeze(.noAllowList) (nothing can pass; the Guard never closes for it)
///  3. ipv6 / route leak  -> freeze (always); dns leak -> freeze only in .block mode (.warn/.off never freeze here)
///  4. confirmation       -> need >= minAgree answers with identical IP AND country (minAgree < 1 is treated as 1;
///                           the live app gives every answer for one address the same country, from
///                           `GeoResolver`, so in practice the IP decides; an empty country = unknown);
///                           otherwise, unanimous country evidence can satisfy a country rule
///                           even when services see several different exit IPs.
///  5. allow list         -> IP matches an exact/CIDR entry OR country is in the list; otherwise freeze.
///                           An EMPTY allow list allows nothing (fail closed).
public func evaluate(_ o: Observation, allow: AllowList, minAgree: Int, dnsCheck: DNSCheckMode,
                     routeHosts: Set<String>? = nil) -> Verdict {
    guard o.online else { return .offline }
    if o.trustedNetwork { return .ok }
    if o.vpnDown { return .freeze(.vpnDown) }
    if allow.ips.isEmpty && allow.countries.isEmpty { return .freeze(.noAllowList) }
    let v6 = o.leakInputs.map { $0.checkIPv6 && detectIPv6Leak(answers: $0.ipv6Answers, allow: allow) } ?? o.ipv6Leak
    if v6 { return .freeze(.ipv6Leak) }
    let route = o.leakInputs.map {
        $0.checkRoutes && detectRouteLeak($0.routes, allow: allow, hosts: routeHosts)
    } ?? o.routeLeak
    if route { return .freeze(.routeLeak) }
    if o.dnsLeak && dnsCheck == .block { return .freeze(.dnsLeak) }

    let quorum = max(1, minAgree)
    var groups: [String: (answer: IPAnswer, count: Int)] = [:]
    for a in o.ips {
        let key = a.ip + "|" + a.country.uppercased()
        groups[key, default: (a, 0)].count += 1
    }
    let confirmed = groups.values.filter { $0.count >= quorum }
    let answer = confirmed.count == 1 ? confirmed.first?.answer : nil
    let country = answer?.country.uppercased() ?? sharedExitCountry(o.ips, minAgree: quorum)
    let allowedIP = answer.map { answer in allow.ips.contains { IPMatcher.matches(answer.ip, entry: $0) } } ?? false
    let allowedCountry = country.map { country in
        !country.isEmpty && allow.countries.contains { $0.uppercased() == country }
    } ?? false
    if allowedIP || allowedCountry {
        if routeHosts != nil, o.leakInputs?.freshRoutesPending == true { return .freeze(.networkChanged) }
        return .ok
    }
    guard let confirmedAnswer = answer else { return .freeze(.unconfirmed) }
    // Address confirmed but no GeoIP database could name its country: not known to be wrong.
    if confirmedAnswer.country.isEmpty && !allow.countries.isEmpty { return .freeze(.unconfirmed) }
    return .freeze(allow.ips.isEmpty && !allow.countries.isEmpty ? .countryNotAllowed : .ipNotAllowed)
}

/// Exact-IP / CIDR matching for IPv4 and IPv6. Anything malformed never matches.
public enum IPMatcher {
    /// An allow-list entry that can ever match: an exact IPv4/IPv6 address, or address/prefix with
    /// 0...32 (IPv4) / 0...128 (IPv6). Surrounding whitespace is NOT accepted (callers trim).
    public static func isValidEntry(_ entry: String) -> Bool {
        let parts = entry.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let net = parse(parts[0]) else { return false }
        if parts.count == 1 { return true }
        let p = parts[1]
        guard !p.isEmpty, p.count <= 3, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p) else { return false }
        return n <= net.count * 8
    }

    /// Prefix length of a CIDR entry (nil for an exact address or a malformed entry).
    public static func prefixLength(_ entry: String) -> Int? {
        let parts = entry.split(separator: "/", maxSplits: 1).map(String.init)
        return parts.count == 2 && isValidEntry(entry) ? Int(parts[1]) : nil
    }

    public static func matches(_ ip: String, entry: String) -> Bool {
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
