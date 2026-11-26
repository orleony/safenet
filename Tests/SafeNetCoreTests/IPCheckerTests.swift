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

/// A service that ignores cancellation: it waits on a continuation that only a timer resumes
/// (no polling loop, so a cancelled task cannot spin).
private struct StubbornService: IPService {
    func fetch() async throws -> IPAnswer {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { c.resume() }
        }
        return IPAnswer(ip: "9.9.9.9", country: "ZZ")
    }
}

/// Counts calls; fails with `error` while it is set.
private final class CountingService: IPService {
    var calls = 0
    var error: Error?
    let answer: IPAnswer
    init(_ a: IPAnswer) { answer = a }
    func fetch() async throws -> IPAnswer {
        calls += 1
        if let e = error { throw e }
        return answer
    }
    var name: String { "count.example" }
}

private final class WallClock { var t = Date(timeIntervalSince1970: 1_800_000_000) }

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
    test("testCheckEachReportsEveryServiceInOrder") {
        let c = IPChecker(services: [
            FakeIPService(answer: IPAnswer(ip: "1.1.1.1", country: "NL"), name: "a.example"),
            FakeIPService(answer: IPAnswer(ip: "2.2.2.2", country: "DE"), error: URLError(.notConnectedToInternet), name: "b.example"),
            FakeIPService(answer: IPAnswer(ip: "3.3.3.3", country: "NL"), delay: 0.1, name: "c.example"),
        ], timeout: 1)
        let r = awaitResult { await c.checkEach() }
        expectEqual(r.map { $0.service }, ["a.example", "b.example", "c.example"])
        expectEqual(r[0].outcome, .answer(IPAnswer(ip: "1.1.1.1", country: "NL")))
        if case .failed(let why) = r[1].outcome {
            expect(!why.isEmpty, "failure has a short reason")
            expect(!why.contains("/"), "no URL or path in the reason: \(why)")
        } else { expect(false, "b must be failed: \(r[1].outcome)") }
        expectEqual(r[2].outcome, .answer(IPAnswer(ip: "3.3.3.3", country: "NL")))
        expectEqual(r[0].answer, IPAnswer(ip: "1.1.1.1", country: "NL"))
        expectEqual(r[1].answer, nil)
    }
    test("testCheckEachMarksSlowServicesAsTimedOut") {
        let c = IPChecker(services: [
            FakeIPService(answer: IPAnswer(ip: "1.1.1.1", country: "NL")),
            FakeIPService(answer: IPAnswer(ip: "2.2.2.2", country: "NL"), delay: 5),
            StubbornService(),
        ], timeout: 0.4)
        let t0 = now()
        let r = awaitResult { await c.checkEach() }
        expect(now() - t0 < 1.0, "returns at the timeout")
        expectEqual(r.count, 3)
        expectEqual(r[0].outcome, .answer(IPAnswer(ip: "1.1.1.1", country: "NL")))
        expectEqual(r[1].outcome, .timedOut)
        expectEqual(r[2].outcome, .timedOut)
    }
    test("testCheckEachNoServices") {
        expectEqual(awaitResult { await IPChecker(services: [], timeout: 1).checkEach() }, [])
    }
    test("testCheckUnchangedByCheckEach") {
        let c = IPChecker(services: [
            FakeIPService(answer: IPAnswer(ip: "1.1.1.1", country: "NL")),
            FakeIPService(answer: IPAnswer(ip: "2.2.2.2", country: "DE"), error: URLError(.timedOut)),
        ], timeout: 1)
        expectEqual(awaitResult { await c.check() }, [IPAnswer(ip: "1.1.1.1", country: "NL")])
    }
    test("testHTTPServiceNameIsHost") {
        expectEqual(HTTPIPService(spec: HTTPIPService.defaults[0]).name, "ipinfo.io")
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

    // MARK: Cloudflare trace service, HTTP status handling, backoff (C1)

    test("testTraceServiceParsesCloudflareTrace") {
        let body = "fl=1\nh=1.1.1.1\nip=203.0.113.7\nts=1\nvisit_scheme=https\nloc=nl\ntls=TLSv1.3\n"
        expectEqual(TraceIPService.parse(body), IPAnswer(ip: "203.0.113.7", country: "NL"))
        expectEqual(TraceIPService.parse("ip=203.0.113.7\n"), nil)
        expectEqual(TraceIPService.parse("<html>"), nil)
        expectEqual(TraceIPService.cloudflare.url.absoluteString, "https://1.1.1.1/cdn-cgi/trace")
        expectEqual(TraceIPService(url: TraceIPService.cloudflare.url).name, "1.1.1.1")
    }
    test("testAddressServicesAreTextAndCloudflareByName") {
        expectEqual(IPServiceSet.cheapHosts, ["www.cloudflare.com", "api.ipify.org"])
        expectEqual(IPServiceSet.ipv4Hosts, ["www.cloudflare.com", "api.ipify.org", "checkip.amazonaws.com", "ipv4.icanhazip.com", "v4.ident.me"])
        expect(!IPServiceSet.ipv4Hosts.contains("1.1.1.1"), "VPNs often route 1.1.1.1 around the tunnel")
        expectEqual(IPServiceSet.makeServices().map { $0.name }, IPServiceSet.ipv4Hosts)
        expect(Set(IPServiceSet.cheapHosts).isSubset(of: Set(IPServiceSet.ipv4Hosts)))
    }
    test("testTextServiceInterpretation") {
        expectEqual(try? TextIPService.interpret(status: 200, body: " 195.133.9.79\n"), IPAnswer(ip: "195.133.9.79", country: ""))
        expectEqual(try? TextIPService.interpret(status: 200, body: "<html>"), nil)
        do { _ = try TextIPService.interpret(status: 429, body: ""); expect(false, "429 must throw") }
        catch let e as HTTPIPService.ServiceError { expectEqual(e, .rateLimited) }
        catch { expect(false, "wrong error \(error)") }
    }
    test("testAddressOnlyDropsCountry") {
        let s = AddressOnly(FakeIPService(answer: IPAnswer(ip: "1.2.3.4", country: "NL"), name: "x"))
        let r: IPAnswer? = awaitResult { () async -> IPAnswer? in do { return try await s.fetch() } catch { return nil } }
        expectEqual(r, IPAnswer(ip: "1.2.3.4", country: ""))
        expectEqual(s.name, "x")
    }
    test("testHTTPStatusInterpretation") {
        let ok = Data(#"{"ip":"1.2.3.4","country":"NL"}"#.utf8)
        expectEqual(try? HTTPIPService.interpret(status: 200, data: ok, spec: spec), IPAnswer(ip: "1.2.3.4", country: "NL"))
        do { _ = try HTTPIPService.interpret(status: 429, data: ok, spec: spec); expect(false, "429 must throw") }
        catch let e as HTTPIPService.ServiceError { expectEqual(e, .rateLimited) }
        catch { expect(false, "wrong error \(error)") }
        do { _ = try HTTPIPService.interpret(status: 503, data: ok, spec: spec); expect(false, "503 must throw") }
        catch let e as HTTPIPService.ServiceError { expectEqual(e, .httpStatus(503)) }
        catch { expect(false, "wrong error \(error)") }
        expectEqual(ServiceResult.reason(HTTPIPService.ServiceError.rateLimited), "лимит запросов (HTTP 429)")
    }
    test("testBackoffSkipsFailedServiceAndGrowsExponentially") {
        let inner = CountingService(IPAnswer(ip: "1.2.3.4", country: "NL"))
        let clock = WallClock()
        let b = BackoffIPService(inner, now: { clock.t })
        inner.error = HTTPIPService.ServiceError.rateLimited
        _ = awaitResult { try? await b.fetch() }
        expectEqual(inner.calls, 1)
        expectEqual(b.currentDelay, 60)
        clock.t += 30
        let skipped: IPAnswer? = awaitResult { try? await b.fetch() }
        expectEqual(skipped, nil)
        expectEqual(inner.calls, 1, "backed off: not contacted")
        clock.t += 31
        _ = awaitResult { try? await b.fetch() }
        expectEqual(inner.calls, 2)
        expectEqual(b.currentDelay, 120, "second failure doubles")
        for _ in 0..<10 { clock.t += 4000; _ = awaitResult { try? await b.fetch() } }
        expectEqual(b.currentDelay, 3600, "capped at 60 min")
        inner.error = nil
        clock.t += 3601
        let back: IPAnswer? = awaitResult { try? await b.fetch() }
        expectEqual(back, IPAnswer(ip: "1.2.3.4", country: "NL"))
        expectEqual(b.currentDelay, 0, "success resets")
        let again: IPAnswer? = awaitResult { try? await b.fetch() }
        expectEqual(again, IPAnswer(ip: "1.2.3.4", country: "NL"), "no backoff after a success")
        expectEqual(b.name, "count.example")
    }
    test("testBackedOffServiceIsAbsentFromAnswers") {
        let good = CountingService(IPAnswer(ip: "1.2.3.4", country: "NL"))
        let bad = CountingService(IPAnswer(ip: "9.9.9.9", country: "ZZ"))
        bad.error = HTTPIPService.ServiceError.httpStatus(503)
        let clock = WallClock()
        let c = IPChecker(services: [BackoffIPService(good, now: { clock.t }), BackoffIPService(bad, now: { clock.t })], timeout: 1)
        expectEqual(awaitResult { await c.check() }, [IPAnswer(ip: "1.2.3.4", country: "NL")])
        bad.error = nil
        expectEqual(awaitResult { await c.check() }, [IPAnswer(ip: "1.2.3.4", country: "NL")], "skipped, never fabricated")
        expectEqual(bad.calls, 1)
        let each = awaitResult { await c.checkEach() }
        if case .failed(let why) = each[1].outcome { expect(why.contains("отложен"), why) } else { expect(false, "\(each[1].outcome)") }
    }

    // MARK: N1: backoff only for rate-limit signals, reset on demand, stale failures ignored

    test("testBackoffIgnoresTransportErrorsAndTimeouts") {
        let inner = CountingService(IPAnswer(ip: "1.2.3.4", country: "NL"))
        let clock = WallClock()
        let b = BackoffIPService(inner, now: { clock.t })
        for e: Error in [URLError(.timedOut), URLError(.notConnectedToInternet), URLError(.networkConnectionLost),
                         CancellationError(), HTTPIPService.ServiceError.badResponse, HTTPIPService.ServiceError.httpStatus(404)] {
            inner.error = e
            _ = awaitResult { try? await b.fetch() }
            expectEqual(b.currentDelay, 0, "no backoff for \(e)")
        }
        expectEqual(inner.calls, 6, "asked every time")
        inner.error = HTTPIPService.ServiceError.httpStatus(502)
        _ = awaitResult { try? await b.fetch() }
        expectEqual(b.currentDelay, 60, "5xx backs off")
        expect(BackoffIPService.countsAsRateLimit(HTTPIPService.ServiceError.rateLimited))
        expect(BackoffIPService.countsAsRateLimit(HTTPIPService.ServiceError.httpStatus(500)))
        expect(!BackoffIPService.countsAsRateLimit(URLError(.timedOut)))
    }
    test("testBackoffResetLetsServiceBeAskedAgain") {
        let inner = CountingService(IPAnswer(ip: "1.2.3.4", country: "NL"))
        let clock = WallClock()
        let b = BackoffIPService(inner, now: { clock.t })
        inner.error = HTTPIPService.ServiceError.rateLimited
        _ = awaitResult { try? await b.fetch() }
        inner.error = nil
        let skipped: IPAnswer? = awaitResult { try? await b.fetch() }
        expectEqual(skipped, nil)
        b.reset()
        expectEqual(b.currentDelay, 0)
        let again: IPAnswer? = awaitResult { try? await b.fetch() }
        expectEqual(again, IPAnswer(ip: "1.2.3.4", country: "NL"), "asked again after reset")
        expectEqual(inner.calls, 2)
    }
    test("testBackoffIgnoresFailureOfAFetchStartedBeforeReset") {
        let clock = WallClock()
        let gate = GatedService()
        let b = BackoffIPService(gate, now: { clock.t })
        let sem = DispatchSemaphore(value: 0)
        Task { _ = try? await b.fetch(); sem.signal() }
        gate.waitUntilStarted()
        b.reset()                                     // network changed while it ran
        gate.finish(with: HTTPIPService.ServiceError.rateLimited)
        sem.wait()
        expectEqual(b.currentDelay, 0, "a failure from a discarded generation is not counted")
    }
}

/// Fetch that blocks until `finish` (to interleave a reset with an in-flight request).
private final class GatedService: IPService {
    private let started = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var cont: CheckedContinuation<Void, Never>?
    private var err: Error?
    private var done = false
    func fetch() async throws -> IPAnswer {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if !park(c) { c.resume() }
            started.signal()
        }
        if let e = currentError() { throw e }
        return IPAnswer(ip: "1.2.3.4", country: "NL")
    }
    private func park(_ c: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        cont = c; return true
    }
    private func currentError() -> Error? { lock.lock(); defer { lock.unlock() }; return err }
    func waitUntilStarted() { started.wait() }
    func finish(with e: Error?) {
        lock.lock(); err = e; done = true; let c = cont; cont = nil; lock.unlock()
        c?.resume()
    }
}
