import Foundation
@testable import SafeNetCore

/// Blocks the (synchronous) test body until an async operation finishes.
private final class Box<T> { var value: T? }
private func awaitResult<T>(_ op: @escaping () async -> T) -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = Box<T>()
    Task { box.value = await op(); sem.signal() }
    sem.wait()
    return box.value!
}

private func now() -> Double { Date().timeIntervalSince1970 }
private let spec = HTTPIPService.Spec(url: URL(string: "https://example.invalid/json")!, ipField: "ip", countryField: "country")
private func parse(_ s: String) -> IPAnswer? { HTTPIPService.parse(Data(s.utf8), spec: spec) }

/// A service that ignores cancellation (blocks a thread-free sleep via continuation-less polling).
private struct StubbornService: IPService {
    func fetch() async throws -> IPAnswer {
        let end = now() + 3
        while now() < end { _ = try? await Task.sleep(nanoseconds: 50_000_000) }
        return IPAnswer(ip: "9.9.9.9", country: "ZZ")
    }
}

func registerIPCheckerTests() {
    test("testReturnsOnlySuccessfulAnswers") {
        let c = IPChecker(services: [
            FakeIPService(answer: IPAnswer(ip: "1.1.1.1", country: "NL")),
            FakeIPService(answer: IPAnswer(ip: "2.2.2.2", country: "DE"), error: URLError(.notConnectedToInternet)),
            FakeIPService(answer: IPAnswer(ip: "3.3.3.3", country: "NL")),
        ], timeout: 1)
        let r = awaitResult { await c.check() }
        expectEqual(r.map { $0.ip }.sorted(), ["1.1.1.1", "3.3.3.3"])
    }
    test("testSlowServiceTimesOut") {
        let c = IPChecker(services: [
            FakeIPService(answer: IPAnswer(ip: "1.1.1.1", country: "NL")),
            FakeIPService(answer: IPAnswer(ip: "2.2.2.2", country: "NL"), delay: 5),
            StubbornService(),
        ], timeout: 0.4)
        let t0 = now()
        let r = awaitResult { await c.check() }
        let dt = now() - t0
        expectEqual(r, [IPAnswer(ip: "1.1.1.1", country: "NL")])
        expect(dt < 1.0, "took \(dt)")
    }
    test("testRunsInParallel") {
        let c = IPChecker(services: (1...3).map {
            FakeIPService(answer: IPAnswer(ip: "1.1.1.\($0)", country: "NL"), delay: 0.3)
        }, timeout: 2)
        let t0 = now()
        let r = awaitResult { await c.check() }
        let dt = now() - t0
        expectEqual(r.count, 3)
        expect(dt < 0.8, "took \(dt)")
    }
    test("testNoServicesReturnsEmpty") {
        let r = awaitResult { await IPChecker(services: [], timeout: 1).check() }
        expectEqual(r, [])
    }
    test("testParseValidIPv4") {
        expectEqual(parse(#"{"ip":"1.2.3.4","country":"NL"}"#), IPAnswer(ip: "1.2.3.4", country: "NL"))
    }
    test("testParseIPv6AndLowercaseCountry") {
        expectEqual(parse(#"{"ip":"2001:db8::1","country":"nl"}"#), IPAnswer(ip: "2001:db8::1", country: "NL"))
    }
    test("testParseRejectsMalformed") {
        expectEqual(parse("not json"), nil)
        expectEqual(parse("[1,2]"), nil)
        expectEqual(parse(""), nil)
    }
    test("testParseRejectsMissingFields") {
        expectEqual(parse(#"{"ip":"1.2.3.4"}"#), nil)
        expectEqual(parse(#"{"country":"NL"}"#), nil)
        expectEqual(parse(#"{"ip":1234,"country":"NL"}"#), nil)
    }
    test("testParseRejectsNonIP") {
        expectEqual(parse(#"{"ip":"example.com","country":"NL"}"#), nil)
        expectEqual(parse(#"{"ip":"1.2.3.4.5","country":"NL"}"#), nil)
        expectEqual(parse(#"{"ip":"<html>","country":"NL"}"#), nil)
    }
    test("testParseRejectsBadCountry") {
        expectEqual(parse(#"{"ip":"1.2.3.4","country":"NLD"}"#), nil)
        expectEqual(parse(#"{"ip":"1.2.3.4","country":"N"}"#), nil)
        expectEqual(parse(#"{"ip":"1.2.3.4","country":"1A"}"#), nil)
        expectEqual(parse(#"{"ip":"1.2.3.4","country":""}"#), nil)
    }
    test("testParseCustomFieldNames") {
        let s = HTTPIPService.Spec(url: spec.url, ipField: "query", countryField: "countryCode")
        expectEqual(HTTPIPService.parse(Data(#"{"query":"5.6.7.8","countryCode":"de"}"#.utf8), spec: s), IPAnswer(ip: "5.6.7.8", country: "DE"))
    }
    test("testDefaultServicesConfigured") {
        expect(HTTPIPService.defaults.count >= 3)
    }
}
