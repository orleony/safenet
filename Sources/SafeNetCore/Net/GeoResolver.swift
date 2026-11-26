import Foundation

/// Country of a given IP address, from one GeoIP database. The address is passed explicitly,
/// so the answer does not depend on the route the request takes.
public protocol GeoSource {
    /// Short label (a host name), shown in the deep check.
    var name: String { get }
    /// Two uppercase letters.
    func country(of ip: String) async throws -> String
}

public enum GeoError: Error, Equatable {
    /// HTTP 429 (or 5xx): the database asks to slow down. `retryAfter` from the header, if any.
    case rateLimited(retryAfter: TimeInterval?)
    case httpStatus(Int)
    case badResponse
    /// Skipped: the database is still in its rate-limit pause.
    case pausedUntil(Date)

    public var reason: String {
        switch self {
        case .rateLimited: return "лимит запросов (HTTP 429)"
        case .httpStatus(let c): return "HTTP \(c)"
        case .badResponse: return "bad response"
        case .pausedUntil: return "пауза после лимита запросов"
        }
    }
}

/// JSON GeoIP endpoint: `template` has `{ip}` in place of the address; `field` holds the code.
public struct HTTPGeoSource: GeoSource {
    public let template: String
    public let field: String
    public let requestTimeout: TimeInterval
    private let session: URLSession

    /// Priority order (Kordon's too): the first valid answer is THE country of the address.
    public static let defaults: [HTTPGeoSource] = [
        HTTPGeoSource(template: "https://ipinfo.io/{ip}/json", field: "country"),
        HTTPGeoSource(template: "https://ipapi.co/{ip}/json/", field: "country_code"),
        HTTPGeoSource(template: "https://api.country.is/{ip}", field: "country"),
        HTTPGeoSource(template: "https://ifconfig.co/json?ip={ip}", field: "country_iso"),
    ]

    public init(template: String, field: String, requestTimeout: TimeInterval = 5) {
        self.template = template; self.field = field; self.requestTimeout = requestTimeout
        session = makeEphemeralSession(timeout: requestTimeout, accept: "application/json")
    }

    public var name: String { URL(string: template.replacingOccurrences(of: "{ip}", with: "0.0.0.0"))?.host ?? "GeoIP" }

    public func country(of ip: String) async throws -> String {
        guard HTTPIPService.isValidIP(ip),
              let url = URL(string: template.replacingOccurrences(of: "{ip}", with: ip)) else { throw GeoError.badResponse }
        var req = URLRequest(url: url)
        req.timeoutInterval = requestTimeout
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw GeoError.badResponse }
        return try HTTPGeoSource.interpret(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                                           data: data, field: field)
    }

    /// Pure: status + Retry-After + body -> country code.
    public static func interpret(status: Int, retryAfter: String?, data: Data, field: String) throws -> String {
        if status == 429 || (500...599).contains(status) {
            throw GeoError.rateLimited(retryAfter: retryAfter.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) })
        }
        guard (200..<300).contains(status) else { throw GeoError.httpStatus(status) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cc = (obj[field] as? String).flatMap(normalisedCountry) else { throw GeoError.badResponse }
        return cc
    }
}

/// "nl " -> "NL"; anything but two ASCII letters -> nil.
public func normalisedCountry(_ s: String) -> String? {
    let cc = s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return cc.utf8.count == 2 && cc.utf8.allSatisfy({ (65...90).contains($0) }) ? cc : nil
}

func makeEphemeralSession(timeout: TimeInterval, accept: String) -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = timeout
    cfg.timeoutIntervalForResource = timeout
    cfg.httpCookieStorage = nil
    cfg.httpShouldSetCookies = false
    cfg.urlCache = nil
    cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    cfg.urlCredentialStorage = nil
    cfg.httpAdditionalHeaders = ["User-Agent": "SafeNet", "Accept": accept]
    return URLSession(configuration: cfg)
}

/// One database's answer about one address (deep check).
public struct GeoAnswer: Equatable {
    public var source: String
    /// Country code, or why there is none.
    public var outcome: Result<String, GeoError>
    public init(source: String, outcome: Result<String, GeoError>) { self.source = source; self.outcome = outcome }
    public var country: String? { if case .success(let c) = outcome { return c } else { return nil } }
}

/// Decides the country of an address the way Kordon does: databases in priority order, the first
/// valid answer wins (databases disagree about VPN exits, so they are never voted). The answer is
/// remembered per address for `ttl`, so the quota-limited databases are asked only when the
/// address changes. A database answering 429/5xx is paused for its Retry-After (else
/// `defaultPause`, at most `maxPause`) and the next one is asked.
public final class GeoResolver {
    public static let ttl: TimeInterval = 24 * 3600
    public static let defaultPause: TimeInterval = 600
    public static let maxPause: TimeInterval = 3600

    public struct Entry: Equatable {
        public var country: String
        public var source: String
        public var at: Date
    }

    private let sources: [GeoSource]
    private let now: () -> Date
    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    private var pausedUntil: [String: Date] = [:]

    public init(sources: [GeoSource], now: @escaping () -> Date = Date.init) {
        self.sources = sources; self.now = now
    }

    /// Remembered answer for `ip` (still fresh), else nil.
    public func cached(_ ip: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard let e = cache[ip], now().timeIntervalSince(e.at) < GeoResolver.ttl else { return nil }
        return e
    }

    /// The country of `ip`: cached, else the first valid answer in priority order. nil = no
    /// database could tell (never guessed).
    public func country(of ip: String) async -> Entry? {
        if let e = cached(ip) { return e }
        for s in sources {
            if paused(s.name) != nil { continue }
            do {
                let cc = try await s.country(of: ip)
                let e = Entry(country: cc, source: s.name, at: now())
                remember(ip, e)
                return e
            } catch {
                note(s.name, error)
            }
        }
        return nil
    }

    /// Every database separately, in priority order (deep check). Paused databases are reported as
    /// such, not asked. The first valid answer is remembered like `country(of:)` would.
    public func lookupAll(_ ip: String) async -> [GeoAnswer] {
        let srcs = sources
        var out = Array<GeoAnswer?>(repeating: nil, count: srcs.count)
        await withTaskGroup(of: (Int, GeoAnswer).self) { group in
            for (i, s) in srcs.enumerated() {
                group.addTask { [self] in
                    if let until = paused(s.name) { return (i, GeoAnswer(source: s.name, outcome: .failure(.pausedUntil(until)))) }
                    do { return (i, GeoAnswer(source: s.name, outcome: .success(try await s.country(of: ip)))) }
                    catch {
                        note(s.name, error)
                        let g = (error as? GeoError) ?? .httpStatus((error as? URLError)?.code.rawValue ?? -1)
                        return (i, GeoAnswer(source: s.name, outcome: .failure(g)))
                    }
                }
            }
            for await (i, a) in group { out[i] = a }
        }
        let answers = out.compactMap { $0 }
        if cached(ip) == nil, let first = answers.first(where: { $0.country != nil }), let cc = first.country {
            remember(ip, Entry(country: cc, source: first.source, at: now()))
        }
        return answers
    }

    /// Forget remembered pauses (network change / manual check). Countries stay: they belong to
    /// the address, not to the network.
    public func resetPauses() { lock.lock(); pausedUntil = [:]; lock.unlock() }

    private func paused(_ name: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        guard let u = pausedUntil[name], now() < u else { return nil }
        return u
    }
    private func remember(_ ip: String, _ e: Entry) {
        lock.lock(); cache[ip] = e
        if cache.count > 64, let oldest = cache.min(by: { $0.value.at < $1.value.at })?.key { cache[oldest] = nil }
        lock.unlock()
    }
    private func note(_ name: String, _ error: Error) {
        guard case .rateLimited(let after)? = error as? GeoError else { return }
        let pause = min(GeoResolver.maxPause, max(1, after ?? GeoResolver.defaultPause))
        lock.lock(); pausedUntil[name] = now().addingTimeInterval(pause); lock.unlock()
    }
}
