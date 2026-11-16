import Foundation
#if canImport(Darwin)
import Darwin
#endif

public protocol IPService {
    func fetch() async throws -> IPAnswer
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
    public init(answer: IPAnswer, delay: TimeInterval = 0, error: Error? = nil) {
        self.answer = answer; self.delay = delay; self.error = error
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

    public enum ServiceError: Error { case badResponse }

    /// Free, no-key endpoints.
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
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let a = HTTPIPService.parse(data, spec: spec) else { throw ServiceError.badResponse }
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
