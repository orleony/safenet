import Foundation
#if canImport(Darwin)
import Darwin
#endif

public protocol IPService {
    func fetch() async throws -> IPAnswer
    /// Short label for the deep check (a host name, never a full URL).
    var name: String { get }
}

extension IPService {
    public var name: String { "IP-сервис" }
}

/// One service's outcome in `IPChecker.checkEach()` (deep check: every answer shown separately).
public struct ServiceResult: Equatable {
    public enum Outcome: Equatable {
        case answer(IPAnswer)
        /// Short reason without URLs or paths, e.g. "URLError -1009" or "bad response".
        case failed(String)
        /// No answer within the checker's timeout.
        case timedOut
    }
    public var service: String
    public var outcome: Outcome
    public init(service: String, outcome: Outcome) { self.service = service; self.outcome = outcome }
    public var answer: IPAnswer? { if case .answer(let a) = outcome { return a } else { return nil } }

    static func reason(_ e: Error) -> String {
        if let u = e as? URLError { return "URLError \(u.code.rawValue)" }
        if let s = e as? HTTPIPService.ServiceError {
            switch s {
            case .rateLimited: return "лимит запросов (HTTP 429)"
            case .httpStatus(let c): return "HTTP \(c)"
            case .badResponse: return "bad response"
            }
        }
        if e is BackoffIPService.Skipped { return "отложен после ошибки (повтор позже)" }
        let n = e as NSError
        return "\(n.domain) \(n.code)"
    }
}

/// Queries all services in parallel and returns only successful answers.
/// `check()` returns within ~`timeout` even if a service ignores cancellation:
/// results are collected through a lock-protected collector and the caller is
/// resumed by whichever comes first (all services done, or the timer).
public final class IPChecker {
    private let services: [IPService]
    private let timeout: TimeInterval

    public init(services: [IPService], timeout: TimeInterval) {
        self.services = services
        self.timeout = timeout
    }

    public func check() async -> [IPAnswer] {
        if services.isEmpty { return [] }
        let collector = Collector(expected: services.count)
        let services = self.services
        let timeout = self.timeout
        return await withCheckedContinuation { (cont: CheckedContinuation<[IPAnswer], Never>) in
            collector.install(cont)
            var tasks: [Task<Void, Never>] = []
            for s in services {
                tasks.append(Task {
                    let a = try? await s.fetch()
                    collector.report(a)
                })
            }
            tasks.append(Task {
                let ns = UInt64(max(0, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                collector.finish()
            })
            collector.onFinish { tasks.forEach { $0.cancel() } }
        }
    }

    /// Deep check: every service's own outcome, in `services` order. Same timeout rule as
    /// `check()`; services still running at the timeout are reported as `.timedOut`.
    public func checkEach() async -> [ServiceResult] {
        if services.isEmpty { return [] }
        let names = services.map { $0.name }
        let box = EachCollector(count: services.count)
        let services = self.services
        let timeout = self.timeout
        let outcomes = await withCheckedContinuation { (cont: CheckedContinuation<[ServiceResult.Outcome?], Never>) in
            box.install(cont)
            var tasks: [Task<Void, Never>] = []
            for (i, s) in services.enumerated() {
                tasks.append(Task {
                    do { box.report(i, .answer(try await s.fetch())) } catch { box.report(i, .failed(ServiceResult.reason(error))) }
                })
            }
            tasks.append(Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                box.finish()
            })
            box.onFinish { tasks.forEach { $0.cancel() } }
        }
        return zip(names, outcomes).map { ServiceResult(service: $0.0, outcome: $0.1 ?? .timedOut) }
    }

    private final class EachCollector {
        private let lock = NSLock()
        private var outcomes: [ServiceResult.Outcome?]
        private var reported = 0
        private var cont: CheckedContinuation<[ServiceResult.Outcome?], Never>?
        private var cleanup: (() -> Void)?
        private var done = false

        init(count: Int) { outcomes = Array(repeating: nil, count: count) }

        func install(_ c: CheckedContinuation<[ServiceResult.Outcome?], Never>) { lock.lock(); cont = c; lock.unlock() }
        func onFinish(_ f: @escaping () -> Void) {
            lock.lock()
            if done { lock.unlock(); f() } else { cleanup = f; lock.unlock() }
        }
        func report(_ i: Int, _ o: ServiceResult.Outcome) {
            lock.lock()
            if done { lock.unlock(); return }
            outcomes[i] = o
            reported += 1
            let all = reported >= outcomes.count
            lock.unlock()
            if all { finish() }
        }
        func finish() {
            lock.lock()
            if done { lock.unlock(); return }
            done = true
            let c = cont, result = outcomes, f = cleanup
            cont = nil; cleanup = nil
            lock.unlock()
            f?()
            c?.resume(returning: result)
        }
    }

    private final class Collector {
        private let lock = NSLock()
        private let expected: Int
        private var reported = 0
        private var answers: [IPAnswer] = []
        private var cont: CheckedContinuation<[IPAnswer], Never>?
        private var cleanup: (() -> Void)?
        private var done = false

        init(expected: Int) { self.expected = expected }

        func install(_ c: CheckedContinuation<[IPAnswer], Never>) {
            lock.lock(); cont = c; lock.unlock()
        }
        func onFinish(_ f: @escaping () -> Void) {
            lock.lock()
            if done { lock.unlock(); f() } else { cleanup = f; lock.unlock() }
        }
        func report(_ a: IPAnswer?) {
            lock.lock()
            if done { lock.unlock(); return }
            if let a = a { answers.append(a) }
            reported += 1
            let all = reported >= expected
            lock.unlock()
            if all { finish() }
        }
        func finish() {
            lock.lock()
            if done { lock.unlock(); return }
            done = true
            let c = cont, result = answers, f = cleanup
            cont = nil; cleanup = nil
            lock.unlock()
            f?()
            c?.resume(returning: result)
        }
    }
}

/// Fixed-answer service for tests and the app's test mode (SAFENET_FAKE_IP=ip,CC).
public struct FakeIPService: IPService {
    public let answer: IPAnswer
    public let delay: TimeInterval
    public let error: Error?
    public let name: String
    public init(answer: IPAnswer, delay: TimeInterval = 0, error: Error? = nil, name: String = "fake") {
        self.answer = answer; self.delay = delay; self.error = error; self.name = name
    }
    public func fetch() async throws -> IPAnswer {
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if let e = error { throw e }
        return answer
    }
}

/// JSON endpoint returning an IP and a 2-letter country. Field names differ per service.
public struct HTTPIPService: IPService {
    public struct Spec: Equatable {
        public var url: URL
        public var ipField: String
        public var countryField: String
        public init(url: URL, ipField: String, countryField: String) {
            self.url = url; self.ipField = ipField; self.countryField = countryField
        }
    }

    public enum ServiceError: Error, Equatable {
        case badResponse
        /// HTTP 429: the free quota is used up (the caller backs off).
        case rateLimited
        /// Any other non-2xx status.
        case httpStatus(Int)
    }

    /// Free, no-key endpoints (IPv4 quorum services; see `IPServiceSet` for which are polled when).
    public static let defaults: [Spec] = [
        Spec(url: URL(string: "https://ipinfo.io/json")!, ipField: "ip", countryField: "country"),
        Spec(url: URL(string: "https://ipapi.co/json")!, ipField: "ip", countryField: "country_code"),
        Spec(url: URL(string: "https://ifconfig.co/json")!, ipField: "ip", countryField: "country_iso"),
        Spec(url: URL(string: "https://api.country.is/")!, ipField: "ip", countryField: "country"),
    ]

    /// IPv6-only endpoint (AAAA record only, no A record; same JSON as v4.ident.me: "ip", "cc"):
    /// answers only when IPv6 traffic actually gets out, which is what IPv6 leak detection needs.
    /// On a network without IPv6 it simply fails and contributes no answer.
    public static let ipv6Only = Spec(url: URL(string: "https://v6.ident.me/json")!, ipField: "ip", countryField: "cc")

    public let spec: Spec
    public let requestTimeout: TimeInterval
    public var name: String { spec.url.host ?? "IP-сервис" }
    private let session: URLSession

    public init(spec: Spec, requestTimeout: TimeInterval = 5) {
        self.spec = spec
        self.requestTimeout = requestTimeout
        // Ephemeral: no cookies, no cache, no credential storage. Default system route/proxy.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = requestTimeout
        cfg.timeoutIntervalForResource = requestTimeout
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCredentialStorage = nil
        cfg.httpAdditionalHeaders = ["User-Agent": "SafeNet", "Accept": "application/json"]
        self.session = URLSession(configuration: cfg)
    }

    public func fetch() async throws -> IPAnswer {
        var req = URLRequest(url: spec.url)
        req.httpMethod = "GET"
        req.timeoutInterval = requestTimeout
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ServiceError.badResponse }
        return try HTTPIPService.interpret(status: http.statusCode, data: data, spec: spec)
    }

    /// Pure: status code + body -> answer. 429 = quota used up; other non-2xx = `httpStatus`.
    public static func interpret(status: Int, data: Data, spec: Spec) throws -> IPAnswer {
        if status == 429 { throw ServiceError.rateLimited }
        guard (200..<300).contains(status) else { throw ServiceError.httpStatus(status) }
        guard let a = parse(data, spec: spec) else { throw ServiceError.badResponse }
        return a
    }

    /// Pure parser: validates IP via inet_pton, normalises country to 2 uppercase letters.
    public static func parse(_ data: Data, spec: Spec) -> IPAnswer? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ip = (obj[spec.ipField] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              isValidIP(ip),
              let cc = (obj[spec.countryField] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              cc.utf8.count == 2, cc.utf8.allSatisfy({ $0 >= 65 && $0 <= 90 })
        else { return nil }
        return IPAnswer(ip: ip, country: cc)
    }

    public static func isValidIP(_ s: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }
}

/// Cloudflare's trace endpoint on the anycast address (`ip=` / `loc=` lines, no key, high limit).
/// Redirects are refused; the body is capped at 4 KB.
public struct TraceIPService: IPService {
    public static let cloudflare = (url: URL(string: "https://1.1.1.1/cdn-cgi/trace")!, ())
    public let url: URL
    public let requestTimeout: TimeInterval
    public var name: String { url.host ?? "IP-сервис" }
    private let session: URLSession

    public init(url: URL = TraceIPService.cloudflare.url, requestTimeout: TimeInterval = 5) {
        self.url = url
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

    public func fetch() async throws -> IPAnswer {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = requestTimeout
        let (bytes, resp) = try await session.bytes(for: req, delegate: NoRedirectDelegate())
        guard let http = resp as? HTTPURLResponse else { throw HTTPIPService.ServiceError.badResponse }
        if http.statusCode == 429 { throw HTTPIPService.ServiceError.rateLimited }
        guard http.statusCode == 200 else { throw HTTPIPService.ServiceError.httpStatus(http.statusCode) }
        var data = Data()
        for try await b in bytes {
            data.append(b)
            if data.count >= 4096 { break }
        }
        guard let a = TraceIPService.parse(String(decoding: data, as: UTF8.self)) else {
            throw HTTPIPService.ServiceError.badResponse
        }
        return a
    }

    /// Same parser as the route probe (`parseTrace`).
    public static func parse(_ text: String) -> IPAnswer? {
        parseTrace(text).map { IPAnswer(ip: $0.ip, country: $0.loc) }
    }
}

/// Which services are asked when (spec ruling R1, "tiered polling"):
///  - CHEAP (periodic tick every `check_interval`): Cloudflare trace on 1.1.1.1 + api.country.is;
///  - FULL fan-out (start, network change, wake, manual check, any doubt, every 10 min):
///    cheap + the quota-limited ipinfo.io / ipapi.co / ifconfig.co + the IPv6-only service.
public enum IPServiceSet {
    public static let cheapHosts = ["1.1.1.1", "api.country.is"]
    public static let countryIs = HTTPIPService.defaults[3]
    public static let quotaLimitedSpecs = Array(HTTPIPService.defaults.prefix(3))
}

/// Mode of one engine check (see `IPServiceSet`).
public enum IPFetchMode: Equatable { case cheap, full }

/// Wraps a service with per-service exponential backoff against RATE LIMITS only: after HTTP 429
/// or 5xx the service is not contacted for 60 s, doubling on every further one up to 60 min; a
/// success resets it. Transport errors, timeouts, offline, other statuses and bad bodies never
/// back off (they say nothing about quotas, and backing off on them would starve the check that
/// follows a VPN reconnect). `reset()` (network change, wake, manual check) clears it and bumps a
/// generation: a request started before the reset never counts. While backed off `fetch()`
/// throws `Skipped` at once, so the service is simply absent from the answers (never fabricated).
public final class BackoffIPService: IPService {
    public enum Skipped: Error { case backedOff }
    public static let base: TimeInterval = 60
    public static let cap: TimeInterval = 3600

    private let inner: IPService
    private let now: () -> Date
    private let lock = NSLock()
    private var delay: TimeInterval = 0
    private var until: Date?
    private var generation = 0

    /// Wall clock on purpose: after a long sleep the backoff is over (uptime would not advance).
    public init(_ inner: IPService, now: @escaping () -> Date = Date.init) {
        self.inner = inner; self.now = now
    }

    public var name: String { inner.name }
    /// Current backoff length (0 = none).
    public var currentDelay: TimeInterval { lock.lock(); defer { lock.unlock() }; return delay }

    /// HTTP 429 and 5xx: the only failures that back off.
    public static func countsAsRateLimit(_ e: Error) -> Bool {
        guard let s = e as? HTTPIPService.ServiceError else { return false }
        switch s {
        case .rateLimited: return true
        case .httpStatus(let c): return (500...599).contains(c)
        case .badResponse: return false
        }
    }

    /// Forget the backoff (and ignore the outcome of requests already in flight).
    public func reset() { lock.lock(); delay = 0; until = nil; generation += 1; lock.unlock() }

    public func fetch() async throws -> IPAnswer {
        guard let gen = startIfAllowed() else { throw Skipped.backedOff }
        do {
            let a = try await inner.fetch()
            finished(gen, failure: nil)
            return a
        } catch {
            finished(gen, failure: error)
            throw error
        }
    }

    private func startIfAllowed() -> Int? {
        lock.lock(); defer { lock.unlock() }
        if let u = until, now() < u { return nil }
        return generation
    }
    private func finished(_ gen: Int, failure: Error?) {
        lock.lock(); defer { lock.unlock() }
        guard gen == generation else { return }          // started before a reset: discarded
        if let e = failure {
            guard BackoffIPService.countsAsRateLimit(e) else { return }
            delay = delay == 0 ? BackoffIPService.base : min(delay * 2, BackoffIPService.cap)
            until = now().addingTimeInterval(delay)
        } else {
            delay = 0; until = nil
        }
    }
}
