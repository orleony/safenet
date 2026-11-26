import Foundation
@testable import SafeNetCore

private func obs(_ answers: [(String, String)], online: Bool = true, v6: Bool = false,
                 dns: Bool = false, route: Bool = false, trusted: Bool = false) -> Observation {
    Observation(online: online, ips: answers.map { IPAnswer(ip: $0.0, country: $0.1) },
                ipv6Leak: v6, dnsLeak: dns, routeLeak: route, trustedNetwork: trusted)
}
private let nl = AllowList(ips: [], countries: ["NL"])

func registerVerdictTests() {
    test("testOkWhenTwoServicesAgreeAllowedCountry") {
        expectEqual(evaluate(obs([("1.2.3.4", "NL"), ("1.2.3.4", "NL")]), allow: nl, minAgree: 2, dnsCheck: .warn), .ok)
    }
    test("testFreezeWhenServicesDisagree") {
        expectEqual(evaluate(obs([("1.2.3.4", "NL"), ("5.6.7.8", "FR")]), allow: nl, minAgree: 2, dnsCheck: .warn), .freeze(.unconfirmed))
        expectEqual(evaluate(obs([("1.2.3.4", "NL"), ("1.2.3.4", "DE")]), allow: nl, minAgree: 2, dnsCheck: .warn), .freeze(.unconfirmed))
    }
    test("testSeveralExitIPsNeedUnanimousCountryEvidenceAndAnExplicitCountryRule") {
        let o = obs([("1.2.3.4", "NL"), ("5.6.7.8", "NL")])
        expectEqual(evaluate(o, allow: nl, minAgree: 2, dnsCheck: .warn), .ok)
        expectEqual(evaluate(o, allow: AllowList(ips: ["1.2.3.4", "5.6.7.8"]),
                             minAgree: 2, dnsCheck: .warn), .freeze(.unconfirmed))
        expectEqual(evaluate(o, allow: nl, minAgree: 3, dnsCheck: .warn), .freeze(.unconfirmed))
    }
    test("testFreezeWhenNoAnswersOnline") {
        expectEqual(evaluate(obs([]), allow: nl, minAgree: 2, dnsCheck: .warn), .freeze(.unconfirmed))
        expectEqual(evaluate(obs([]), allow: nl, minAgree: 0, dnsCheck: .warn), .freeze(.unconfirmed))
    }
    test("testMinAgreeLargerThanAnswers") {
        expectEqual(evaluate(obs([("1.2.3.4", "NL"), ("1.2.3.4", "NL")]), allow: nl, minAgree: 3, dnsCheck: .warn), .freeze(.unconfirmed))
    }
    test("testOfflineIsNotOkAndNotClose") {
        expectEqual(evaluate(obs([], online: false), allow: nl, minAgree: 2, dnsCheck: .warn), .offline)
        // offline wins even over a trusted network flag
        expectEqual(evaluate(obs([], online: false, trusted: true), allow: nl, minAgree: 2, dnsCheck: .warn), .offline)
    }
    test("testTrustedNetworkAllowsWithoutVpn") {
        expectEqual(evaluate(obs([("9.9.9.9", "RU")], trusted: true), allow: nl, minAgree: 2, dnsCheck: .warn), .ok)
        expectEqual(evaluate(obs([], trusted: true), allow: nl, minAgree: 2, dnsCheck: .block), .ok)
    }
    test("testIPv6LeakFreezes") {
        expectEqual(evaluate(obs([("1.2.3.4", "NL"), ("1.2.3.4", "NL")], v6: true), allow: nl, minAgree: 2, dnsCheck: .off), .freeze(.ipv6Leak))
    }
    test("testRouteLeakFreezes") {
        expectEqual(evaluate(obs([("1.2.3.4", "NL"), ("1.2.3.4", "NL")], route: true), allow: nl, minAgree: 2, dnsCheck: .off), .freeze(.routeLeak))
    }
    test("testDNSLeakWarnDoesNotFreeze") {
        expectEqual(evaluate(obs([("1.2.3.4", "NL"), ("1.2.3.4", "NL")], dns: true), allow: nl, minAgree: 2, dnsCheck: .warn), .ok)
        expectEqual(evaluate(obs([("1.2.3.4", "NL"), ("1.2.3.4", "NL")], dns: true), allow: nl, minAgree: 2, dnsCheck: .off), .ok)
    }
    test("testDNSLeakBlockFreezes") {
        expectEqual(evaluate(obs([("1.2.3.4", "NL"), ("1.2.3.4", "NL")], dns: true), allow: nl, minAgree: 2, dnsCheck: .block), .freeze(.dnsLeak))
    }
    test("testCountryNotAllowed") {
        expectEqual(evaluate(obs([("1.2.3.4", "RU"), ("1.2.3.4", "RU")]), allow: nl, minAgree: 2, dnsCheck: .warn), .freeze(.countryNotAllowed))
    }
    test("testCountryCaseInsensitive") {
        expectEqual(evaluate(obs([("1.2.3.4", "nl"), ("1.2.3.4", "NL")]), allow: AllowList(countries: ["nL"]), minAgree: 2, dnsCheck: .warn), .ok)
    }
    test("testAllowByExactIP") {
        let a = AllowList(ips: ["1.2.3.4"])
        expectEqual(evaluate(obs([("1.2.3.4", "XX")]), allow: a, minAgree: 1, dnsCheck: .warn), .ok)
        expectEqual(evaluate(obs([("1.2.3.5", "XX")]), allow: a, minAgree: 1, dnsCheck: .warn), .freeze(.ipNotAllowed))
    }
    test("testAllowByCIDR") {
        let a = AllowList(ips: ["185.12.40.0/24"])
        expectEqual(evaluate(obs([("185.12.40.7", "DE"), ("185.12.40.7", "DE")]), allow: a, minAgree: 2, dnsCheck: .warn), .ok)
        expectEqual(evaluate(obs([("185.12.40.255", "DE")]), allow: a, minAgree: 1, dnsCheck: .warn), .ok)
        expectEqual(evaluate(obs([("185.12.40.0", "DE")]), allow: a, minAgree: 1, dnsCheck: .warn), .ok)
        expectEqual(evaluate(obs([("185.12.41.0", "DE")]), allow: a, minAgree: 1, dnsCheck: .warn), .freeze(.ipNotAllowed))
        expectEqual(evaluate(obs([("185.12.39.255", "DE")]), allow: a, minAgree: 1, dnsCheck: .warn), .freeze(.ipNotAllowed))
    }
    test("testCIDREdgePrefixes") {
        expect(IPMatcher.matches("8.8.8.8", entry: "0.0.0.0/0"))
        expect(IPMatcher.matches("8.8.8.8", entry: "8.8.8.8/32"))
        expect(!IPMatcher.matches("8.8.8.9", entry: "8.8.8.8/32"))
        expect(!IPMatcher.matches("8.8.8.8", entry: "8.8.8.8/33"))
        expect(!IPMatcher.matches("8.8.8.8", entry: "8.8.8.8/-1"))
        expect(!IPMatcher.matches("8.8.8.8", entry: "8.8.8.8/"))
        expect(!IPMatcher.matches("8.8.8.8", entry: "8.8.8.8/x"))
    }
    test("testIPv6ExactAndCIDR") {
        expect(IPMatcher.matches("2001:db8::1", entry: "2001:0db8:0:0:0:0:0:1"))
        expect(IPMatcher.matches("2001:db8::ffff", entry: "2001:db8::/32"))
        expect(!IPMatcher.matches("2001:db9::1", entry: "2001:db8::/32"))
        expect(!IPMatcher.matches("2001:db8::1", entry: "1.2.3.4/0"))   // family mismatch
        expect(!IPMatcher.matches("1.2.3.4", entry: "::/0"))
    }
    test("testMalformedIPNeverMatches") {
        for bad in ["", "abc", "1.2.3", "1.2.3.4.5", "256.1.1.1", "1.2.3.4/", "/24", "1.2.3.4/24/1", " 1.2.3.4", "999.999.999.999/8"] {
            expect(!IPMatcher.matches(bad, entry: "0.0.0.0/0"), "ip \(bad)")
            expect(!IPMatcher.matches("1.2.3.4", entry: bad), "entry \(bad)")
        }
        let a = AllowList(ips: ["1.2.3.4"])
        expectEqual(evaluate(obs([("garbage", "NL"), ("garbage", "NL")]), allow: a, minAgree: 2, dnsCheck: .warn), .freeze(.ipNotAllowed))
    }
    test("testPerAppRuleReplacesCommonAllowlist") {
        // the caller passes the per-app list INSTEAD of the common one
        let common = AllowList(countries: ["NL"])
        let perApp = AllowList(countries: ["DE"])
        let o = obs([("1.2.3.4", "NL"), ("1.2.3.4", "NL")])
        expectEqual(evaluate(o, allow: common, minAgree: 2, dnsCheck: .warn), .ok)
        expectEqual(evaluate(o, allow: perApp, minAgree: 2, dnsCheck: .warn), .freeze(.countryNotAllowed))
        var cfg = Config.default
        cfg.allow = common; cfg.appRules = ["Telegram": perApp]
        expectEqual(evaluate(o, allow: effectiveAllow(for: "Telegram", in: cfg), minAgree: 2, dnsCheck: .warn), .freeze(.countryNotAllowed))
        expectEqual(evaluate(o, allow: effectiveAllow(for: "Other", in: cfg), minAgree: 2, dnsCheck: .warn), .ok)
    }
    test("testEmptyAllowListAllowsNothing") {
        expectEqual(evaluate(obs([("1.2.3.4", "NL"), ("1.2.3.4", "NL")]), allow: AllowList(), minAgree: 2, dnsCheck: .warn), .freeze(.noAllowList))
        var leaky = obs([("1.2.3.4", "NL"), ("1.2.3.4", "NL")]); leaky.routeLeak = true
        expectEqual(evaluate(leaky, allow: AllowList(), minAgree: 2, dnsCheck: .warn), .freeze(.noAllowList), "empty list decides first")
        expectEqual(evaluate(obs([]), allow: AllowList(), minAgree: 2, dnsCheck: .warn), .freeze(.noAllowList))
    }
    test("testConflictingQuorumsAreUnconfirmed") {
        expectEqual(evaluate(obs([("1.2.3.4", "NL"), ("5.6.7.8", "RU")]), allow: nl, minAgree: 1, dnsCheck: .warn), .freeze(.unconfirmed))
    }
    test("testIPMatcherValidEntry") {
        for ok in ["1.2.3.4", "10.0.0.0/8", "0.0.0.0/0", "2001:db8::1", "2001:db8::/32"] { expect(IPMatcher.isValidEntry(ok), ok) }
        for bad in ["", "1.2.3", "10.0.0.0/33", "10.0.0.0/", "/8", "a.b.c.d", " 1.2.3.4", "2001:db8::/129", "1.2.3.4/0x"] {
            expect(!IPMatcher.isValidEntry(bad), bad)
        }
        expectEqual(IPMatcher.prefixLength("10.0.0.0/8"), 8)
        expectEqual(IPMatcher.prefixLength("10.0.0.1"), nil)
    }

    // MARK: I3: route / IPv6 leaks judged per app

    test("testRouteLeakIsJudgedPerApp") {
        var c = Config.default
        c.apps = ["claude", "telegram"]
        c.appRules = ["claude": AllowList(countries: ["NL"]), "telegram": AllowList(countries: ["RU"])]
        let snap = NetSnapshot(online: true, hasTunnel: true, gatewayIP: nil, gatewayMAC: nil, proxy: nil)
        let routes = [RouteResult(host: "api.anthropic.com", ip: "5.5.5.5", country: "RU", error: nil)]
        var o = NetworkSampler.makeObservation(snapshot: snap, answers: [], routes: routes, resolvers: nil,
                                               allow: AllowList(), config: c)
        o.ips = [IPAnswer(ip: "185.1.1.1", country: "RU"), IPAnswer(ip: "185.1.1.1", country: "RU")]
        let claude = AllowList(ips: ["185.1.1.1"], countries: ["NL"])
        expectEqual(evaluate(o, allow: claude, minAgree: 2, dnsCheck: .warn), .freeze(.routeLeak), "route via RU: leak for Claude")
        expectEqual(evaluate(o, allow: effectiveAllow(for: "telegram", in: c), minAgree: 2, dnsCheck: .warn), .ok,
                    "the same route is fine for Telegram (RU allowed)")
    }
    test("testIPv6LeakIsJudgedPerApp") {
        var c = Config.default
        c.apps = ["claude", "telegram"]
        let snap = NetSnapshot(online: true, hasTunnel: true, gatewayIP: nil, gatewayMAC: nil, proxy: nil)
        let answers = [IPAnswer(ip: "185.1.1.1", country: "RU"), IPAnswer(ip: "185.1.1.1", country: "RU"),
                       IPAnswer(ip: "2a00::1", country: "RU")]
        var o = NetworkSampler.makeObservation(snapshot: snap, answers: answers, routes: nil, resolvers: nil,
                                               allow: AllowList(), config: c)
        o.ips = Array(answers.prefix(2))               // the engine keeps only IPv4 for the quorum
        expectEqual(evaluate(o, allow: AllowList(ips: ["185.1.1.1"], countries: ["NL"]), minAgree: 2, dnsCheck: .warn),
                    .freeze(.ipv6Leak))
        expectEqual(evaluate(o, allow: AllowList(countries: ["RU"]), minAgree: 2, dnsCheck: .warn), .ok)
    }
    test("testPerAppLeakInputsKeepFailClosedSemantics") {
        var c = Config.default; c.apps = ["claude"]
        let snap = NetSnapshot(online: true, hasTunnel: true, gatewayIP: nil, gatewayMAC: nil, proxy: nil)
        let good = [IPAnswer(ip: "1.2.3.4", country: "NL"), IPAnswer(ip: "1.2.3.4", country: "NL")]
        func o(_ routes: [RouteResult]?) -> Observation {
            NetworkSampler.makeObservation(snapshot: snap, answers: good, routes: routes, resolvers: nil, allow: nl, config: c)
        }
        expectEqual(evaluate(o(nil), allow: nl, minAgree: 2, dnsCheck: .warn), .ok, "nil = not evaluated")
        expectEqual(evaluate(o([]), allow: nl, minAgree: 2, dnsCheck: .warn), .freeze(.routeLeak), "zero results = leak")
        let failed = [RouteResult(host: "claude.ai", ip: nil, country: nil, error: "x")]
        expectEqual(evaluate(o(failed), allow: nl, minAgree: 2, dnsCheck: .warn), .freeze(.routeLeak))
        c.routeCheck = false
        let off = NetworkSampler.makeObservation(snapshot: snap, answers: good, routes: [], resolvers: nil, allow: nl, config: c)
        expectEqual(evaluate(off, allow: nl, minAgree: 2, dnsCheck: .warn), .ok, "route check off")
    }
}
