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
        expectEqual(evaluate(obs([("1.2.3.4", "NL"), ("5.6.7.8", "NL")]), allow: nl, minAgree: 2, dnsCheck: .warn), .freeze(.unconfirmed))
        expectEqual(evaluate(obs([("1.2.3.4", "NL"), ("1.2.3.4", "DE")]), allow: nl, minAgree: 2, dnsCheck: .warn), .freeze(.unconfirmed))
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
        expectEqual(evaluate(obs([("1.2.3.4", "NL"), ("1.2.3.4", "NL")]), allow: AllowList(), minAgree: 2, dnsCheck: .warn), .freeze(.ipNotAllowed))
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
}
