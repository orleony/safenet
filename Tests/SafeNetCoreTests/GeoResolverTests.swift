import Foundation
@testable import SafeNetCore

private final class GBox<T> { var value: T? }
private func wait<T>(_ op: @escaping () async -> T) -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = GBox<T>()
    Task { box.value = await op(); sem.signal() }
    sem.wait()
    return box.value!
}

private final class FakeGeo: GeoSource {
    let name: String
    var answer: String?
    var error: GeoError?
    var calls = 0
    init(_ name: String, _ answer: String?, error: GeoError? = nil) { self.name = name; self.answer = answer; self.error = error }
    func country(of ip: String) async throws -> String {
        calls += 1
        if let e = error { throw e }
        guard let a = answer else { throw GeoError.badResponse }
        return a
    }
}

private final class GeoClock { var t = Date(timeIntervalSince1970: 1_800_000_000) }

func registerGeoResolverTests() {
    test("testGeoFirstValidAnswerWinsNotVote") {
        // The screenshot case: country.is says NL, ifconfig.co says CZ for the same address.
        let a = FakeGeo("ipinfo.io", nil, error: .rateLimited(retryAfter: nil))
        let b = FakeGeo("api.country.is", "NL")
        let c = FakeGeo("ifconfig.co", "CZ")
        let r = GeoResolver(sources: [a, b, c])
        let e = wait { await r.country(of: "195.133.9.79") }
        expectEqual(e?.country, "NL"); expectEqual(e?.source, "api.country.is")
        expectEqual(c.calls, 0, "later databases are not asked once one answered")
    }
    test("testGeoRemembersCountryPerAddress") {
        let clock = GeoClock()
        let a = FakeGeo("ipinfo.io", "NL")
        let r = GeoResolver(sources: [a], now: { clock.t })
        _ = wait { await r.country(of: "1.2.3.4") }
        _ = wait { await r.country(of: "1.2.3.4") }
        expectEqual(a.calls, 1, "cached: one request per address")
        _ = wait { await r.country(of: "5.6.7.8") }
        expectEqual(a.calls, 2, "a new address is looked up")
        clock.t += GeoResolver.ttl + 1
        expectEqual(r.cached("1.2.3.4"), nil, "expired")
        _ = wait { await r.country(of: "1.2.3.4") }
        expectEqual(a.calls, 3)
    }
    test("testGeoRateLimitPausesThatDatabaseHonouringRetryAfter") {
        let clock = GeoClock()
        let a = FakeGeo("ipinfo.io", nil, error: .rateLimited(retryAfter: 120))
        let b = FakeGeo("ipapi.co", "DE")
        let r = GeoResolver(sources: [a, b], now: { clock.t })
        _ = wait { await r.country(of: "1.1.1.1") }
        _ = wait { await r.country(of: "2.2.2.2") }
        expectEqual(a.calls, 1, "paused after 429")
        clock.t += 121
        a.error = nil; a.answer = "NL"
        expectEqual(wait { await r.country(of: "3.3.3.3") }?.country, "NL", "back after Retry-After")
        a.error = .rateLimited(retryAfter: nil)
        _ = wait { await r.country(of: "4.4.4.4") }
        clock.t += GeoResolver.defaultPause - 1
        _ = wait { await r.country(of: "5.5.5.5") }
        expectEqual(a.calls, 3, "default pause without Retry-After")
        r.resetPauses()
        _ = wait { await r.country(of: "6.6.6.6") }
        expectEqual(a.calls, 4, "network change / manual check clears pauses")
    }
    test("testGeoNoAnswerIsNil") {
        let r = GeoResolver(sources: [FakeGeo("a", nil), FakeGeo("b", nil, error: .httpStatus(404))])
        expectEqual(wait { await r.country(of: "1.2.3.4") }, nil)
    }
    test("testGeoLookupAllReportsEachInOrder") {
        let r = GeoResolver(sources: [FakeGeo("ipinfo.io", nil, error: .rateLimited(retryAfter: nil)),
                                      FakeGeo("api.country.is", "NL"), FakeGeo("ifconfig.co", "CZ")])
        let all = wait { await r.lookupAll("195.133.9.79") }
        expectEqual(all.map { $0.source }, ["ipinfo.io", "api.country.is", "ifconfig.co"])
        expectEqual(all.map { $0.country }, [nil, "NL", "CZ"])
        expectEqual(r.cached("195.133.9.79")?.country, "NL", "first valid answer remembered")
    }
    test("testGeoHTTPInterpretation") {
        let ok = Data(#"{"country":"nl"}"#.utf8)
        expectEqual(try? HTTPGeoSource.interpret(status: 200, retryAfter: nil, data: ok, field: "country"), "NL")
        expectEqual(try? HTTPGeoSource.interpret(status: 200, retryAfter: nil, data: Data("{}".utf8), field: "country"), nil)
        do { _ = try HTTPGeoSource.interpret(status: 429, retryAfter: " 30", data: ok, field: "country"); expect(false, "must throw") }
        catch let e as GeoError { expectEqual(e, .rateLimited(retryAfter: 30)) }
        catch { expect(false, "\(error)") }
        expectEqual(HTTPGeoSource.defaults.map { $0.name }, ["ipinfo.io", "ipapi.co", "api.country.is", "ifconfig.co"])
        expectEqual(normalisedCountry("Netherlands"), nil)
    }
    test("testLegacyIPServicesMigrate") {
        expectEqual(Config.migrateIPServices(["1.1.1.1", "api.country.is", "ipinfo.io"]), IPServiceSet.ipv4Hosts)
        expectEqual(Config.migrateIPServices(["api.ipify.org", "v4.ident.me"]), ["api.ipify.org", "v4.ident.me"])
    }
    test("testConfirmedAddressWithUnknownCountry") {
        let allow = AllowList(ips: [], countries: ["NL"])
        let o = Observation(online: true, ips: [IPAnswer(ip: "1.2.3.4", country: ""), IPAnswer(ip: "1.2.3.4", country: "")],
                            ipv6Leak: false, dnsLeak: false, routeLeak: false, trustedNetwork: false)
        expectEqual(evaluate(o, allow: allow, minAgree: 2, dnsCheck: .warn), .freeze(.unconfirmed))
        expectEqual(evaluate(o, allow: AllowList(ips: ["1.2.3.4"], countries: ["NL"]), minAgree: 2, dnsCheck: .warn), .ok)
    }
}
