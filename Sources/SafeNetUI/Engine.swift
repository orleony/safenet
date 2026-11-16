import Foundation
import SafeNetCore

/// Everything the UI shows about the protection, in one value (published on every change).
public struct EngineStatus: Equatable {
    public var state: GuardState = .ok
    public var frozenApps: Set<String> = []
    public var releasedApps: Set<String> = []
    public var freezeFailedApps: Set<String> = []
    /// Answers of the last finished check (all services, IPv4 and IPv6).
    public var answers: [IPAnswer] = []
    /// The single IP + country confirmed by >= min_agree services, else nil.
    public var confirmed: IPAnswer?
    public var snapshot: NetSnapshot?
    public var observation: Observation?
    /// DNS resolvers unreadable while a tunnel is up (warning only under dns_check: warn).
    public var dnsUnknown = false
    /// At least one route probe finished and is part of the evaluation.
    public var routesChecked = false
    public var lastCheck: Date?
    public init() {}
}

/// Injected dependencies of the `Engine` (tests replace all of them).
public struct EngineDeps {
    public var clock: Clock
    public var freezer: Freezer
    public var log: EventLog
    public var store: ConfigStore
    /// Fetches IP answers; must call back on the engine's queue (tests: synchronously).
    public var fetchAnswers: (@escaping ([IPAnswer]) -> Void) -> Void
    /// Route probes for the given hosts; same callback rule.
    public var probeRoutes: ([String], @escaping ([RouteResult]) -> Void) -> Void
    /// DNS resolvers (scutil); nil = unknown.
    public var resolvers: () -> [DNSResolver]?
    /// Snapshot used when the monitor has not delivered one yet (or after wake).
    public var snapshotNow: () -> NetSnapshot
    /// Queue for Guard callbacks and config hot reload; nil = synchronous (tests).
    public var queue: DispatchQueue?
    public var tickInterval: TimeInterval = 1
    public var routeInterval: TimeInterval = 120

    public init(clock: Clock, freezer: Freezer, log: EventLog, store: ConfigStore,
                fetchAnswers: @escaping (@escaping ([IPAnswer]) -> Void) -> Void,
                probeRoutes: @escaping ([String], @escaping ([RouteResult]) -> Void) -> Void,
                resolvers: @escaping () -> [DNSResolver]?, snapshotNow: @escaping () -> NetSnapshot,
                queue: DispatchQueue?) {
        self.clock = clock; self.freezer = freezer; self.log = log; self.store = store
        self.fetchAnswers = fetchAnswers; self.probeRoutes = probeRoutes; self.resolvers = resolvers
        self.snapshotNow = snapshotNow; self.queue = queue
    }
}

/// Non-UI orchestration: the driver loop around `Guard`.
///
/// Confinement: every method must be called on one serial queue (`deps.queue` in the app; the
/// test thread in tests). Timers come from `deps.clock` (in the app a `SystemClock` on that queue).
///
/// Loop: network change / wake -> `Guard.networkChanged()` (instant freeze pending a check) and a
/// fresh check; poll every `check_interval`; `Guard.tick()` every second (resume retries, catch-up
/// freezing); route probes (only the five AI hosts) every 120 s and after a network change, only
/// while protected apps exist and `route_check` is on. A check whose network changed while it ran
/// is discarded (its answers may come from the old network).
public final class Engine {
    public private(set) var config: Config
    public let guardian: Guard
    public private(set) var status = EngineStatus()

    public var onStatus: ((EngineStatus) -> Void)?
    public var onConfig: ((Config) -> Void)?
    public var onConfigError: ((String) -> Void)?

    private let deps: EngineDeps
    private var snapshot: NetSnapshot?
    private var routes: [RouteResult]?
    private var lastSample: NetworkSampler.Sample?
    private var lastAnswers: [IPAnswer] = []
    private var lastCheck: Date?
    private var checking = false
    private var recheck = false
    private var netGen = 0
    private var probing = false
    private var pollTimer: Cancellable?
    private var tickTimer: Cancellable?
    private var routeTimer: Cancellable?
    private var running = false
    /// Error met while loading the config at init (reported once `start()` runs).
    private var startupError: String?

    public init(deps: EngineDeps) {
        self.deps = deps
        var err: String?
        config = Engine.loadOrCreate(deps.store, error: &err)
        startupError = err
        guardian = Guard(config: config, freezer: deps.freezer, clock: deps.clock, log: deps.log)
        guardian.callbackQueue = deps.queue
    }

    /// Missing file -> defaults written to disk. Broken file -> defaults in memory (nothing is
    /// protected, file left untouched for the user to fix) and an error.
    static func loadOrCreate(_ store: ConfigStore, error: inout String?) -> Config {
        if !FileManager.default.fileExists(atPath: store.url.path) {
            do { try store.save(.default) } catch let e { error = "не удалось создать config.yaml: \(e)" }
            return .default
        }
        do { return try store.load() } catch let e {
            error = "\(e)"
            return .default
        }
    }

    // MARK: Lifecycle

    public func start(watchConfig: Bool = true) {
        guard !running else { return }
        running = true
        if let e = startupError { onConfigError?(e); startupError = nil }
        // Startup recovery: resume whatever a previous run left stopped (retried, then each tick).
        var left = deps.freezer.reconcile()
        var tries = 0
        while !left.isEmpty && tries < 5 { usleep(100_000); left = deps.freezer.reconcile(); tries += 1 }

        guardian.onChange = { [weak self] _ in self?.publish() }
        guardian.onCheckRequested = { [weak self] in self?.checkNow() }
        guardian.onAllowIP = { [weak self] ip in
            self?.updateConfig { c in if !c.allow.ips.contains(ip) { c.allow.ips.append(ip) } }
        }
        if watchConfig {
            deps.store.watch(queue: deps.queue ?? DispatchQueue(label: "safenet.engine.config")) { [weak self] r in
                switch r {
                case .success(let c): self?.apply(config: c)
                case .failure(let e): self?.onConfigError?("\(e)")
                }
            }
        }
        schedulePoll()
        scheduleTick()
        // Instant (precautionary) freeze until the first check confirms the network.
        guardian.networkChanged()
        updateRouteSchedule(after: 0)
        publish()
    }

    /// Stops everything and resumes every frozen process (retried until empty or `deadline`).
    /// Returns pids that are still stopped (the watchdog / next start retries them).
    @discardableResult
    public func shutdown(deadline: TimeInterval = 2) -> Set<Int32> {
        running = false
        pollTimer?.cancel(); tickTimer?.cancel(); routeTimer?.cancel()
        deps.store.stopWatching()
        var none = config
        none.apps = []; none.customApps = []
        guardian.updateConfig(none)                  // releases every app, no new freezes, no timers
        var left = deps.freezer.resumeAll()
        let end = Date().addingTimeInterval(deadline)
        while !left.isEmpty && Date() < end { usleep(100_000); left = deps.freezer.resumeAll() }
        return left
    }

    // MARK: Events

    /// The network monitor saw a change (also the first snapshot after start).
    public func networkChanged(_ s: NetSnapshot) {
        guard running else { return }
        snapshot = s
        netGen += 1
        guardian.networkChanged()                   // requests a check through onCheckRequested
        updateRouteSchedule(after: 0)
    }

    public func willSleep() { guardian.willSleep() }

    public func didWake() {
        guard running else { return }
        snapshot = nil                              // re-read: the network may be different now
        netGen += 1
        guardian.didWake()
        guardian.networkChanged()
        updateRouteSchedule(after: 2)
    }

    /// Starts a check now (coalesced with one in flight).
    public func checkNow() {
        guard running else { return }
        if checking { recheck = true; return }
        checking = true
        let snap = snapshot ?? deps.snapshotNow()
        snapshot = snap
        let gen = netGen
        if !snap.online { finish([], gen); return }
        deps.fetchAnswers { [weak self] a in self?.finish(a, gen) }
    }

    private func finish(_ answers: [IPAnswer], _ gen: Int) {
        checking = false
        guard running else { return }
        if gen != netGen {                           // network changed meanwhile: stale answers
            recheck = false
            checkNow()
            return
        }
        lastAnswers = answers
        evaluateAndApply()
        if recheck { recheck = false; checkNow() }
    }

    private func evaluateAndApply() {
        let snap = snapshot ?? deps.snapshotNow()
        let wantDNS = config.dnsCheck != .off && snap.hasTunnel
        var s = NetworkSampler.makeSample(snapshot: snap, answers: lastAnswers, routes: routesActive ? routes : nil,
                                          resolvers: wantDNS ? deps.resolvers() : nil,
                                          allow: Engine.leakAllow(config), config: config)
        s.observation.ips = Engine.quorumAnswers(lastAnswers)
        lastSample = s
        lastCheck = deps.clock.now
        guardian.apply(s.observation)
        publish()
    }

    // MARK: Actions

    public func updateConfig(_ mutate: (inout Config) -> Void) {
        var c = config
        mutate(&c)
        guard c != config else { return }
        do { try deps.store.save(c) } catch { onConfigError?("не удалось сохранить config.yaml: \(error)") }
        apply(config: c)
    }

    /// First run: allow the country of the currently confirmed IP. False when nothing is confirmed.
    @discardableResult
    public func allowCurrentCountry() -> Bool {
        guard let cc = status.confirmed?.country, !cc.isEmpty else { return false }
        updateConfig { c in if !c.allow.countries.contains(cc) { c.allow.countries.append(cc) } }
        return true
    }

    public func toggleApp(_ id: String) {
        updateConfig { c in
            if let i = c.apps.firstIndex(of: id) { c.apps.remove(at: i) } else { c.apps.append(id) }
        }
    }

    private func apply(config c: Config) {
        let oldInterval = config.checkInterval
        let wasActive = routesActive
        config = c
        guardian.updateConfig(c)
        if oldInterval != c.checkInterval { schedulePoll() }
        if wasActive != routesActive { updateRouteSchedule(after: 0) }
        onConfig?(c)
        if lastSample != nil { evaluateAndApply() } else { publish() }
    }

    // MARK: Timers

    private func schedulePoll() {
        pollTimer?.cancel()
        guard running else { return }
        pollTimer = deps.clock.schedule(after: max(1, config.checkInterval)) { [weak self] in
            self?.checkNow(); self?.schedulePoll()
        }
    }

    private func scheduleTick() {
        tickTimer?.cancel()
        guard running else { return }
        tickTimer = deps.clock.schedule(after: deps.tickInterval) { [weak self] in
            self?.guardian.tick(); self?.publish(); self?.scheduleTick()
        }
    }

    /// Route checking is meaningful (and allowed to touch the network) only with protected apps.
    var routesActive: Bool { config.routeCheck && !AppCatalog.appIDs(in: config).isEmpty }

    private func updateRouteSchedule(after delay: TimeInterval) {
        routeTimer?.cancel(); routeTimer = nil
        guard running, routesActive else { routes = nil; return }
        routeTimer = deps.clock.schedule(after: delay) { [weak self] in self?.runRouteProbe() }
    }

    private func runRouteProbe() {
        guard running, routesActive, !probing else { return }
        probing = true
        let gen = netGen
        deps.probeRoutes(URLSessionTraceFetcher.hosts) { [weak self] r in
            guard let self = self else { return }
            self.probing = false
            guard self.running, self.routesActive else { self.routes = nil; return }
            if gen == self.netGen { self.routes = r; self.checkNow() }
            self.updateRouteSchedule(after: gen == self.netGen ? self.deps.routeInterval : 0)
        }
    }

    // MARK: Status

    private func publish() {
        var s = EngineStatus()
        s.state = guardian.state
        s.frozenApps = guardian.frozenApps
        s.releasedApps = guardian.releasedApps
        s.freezeFailedApps = guardian.freezeFailedApps
        s.answers = lastAnswers
        s.confirmed = Engine.confirmed(Engine.quorumAnswers(lastAnswers), minAgree: config.minAgree)
        s.snapshot = snapshot
        s.observation = lastSample?.observation
        s.dnsUnknown = lastSample?.dnsUnknown ?? false
        s.routesChecked = routesActive && routes != nil
        s.lastCheck = lastCheck
        guard s != status else { return }
        status = s
        onStatus?(s)
    }

    // MARK: Pure helpers

    /// The answers that take part in the IP/country quorum: IPv4 ones when there are any. An
    /// IPv6-only service would otherwise form a second group (min_agree 1 -> "unconfirmed");
    /// IPv6 answers are still checked for leaks by the sampler.
    static func quorumAnswers(_ a: [IPAnswer]) -> [IPAnswer] {
        let v4 = a.filter { !$0.ip.contains(":") }
        return v4.isEmpty ? a : v4
    }

    static func confirmed(_ a: [IPAnswer], minAgree: Int) -> IPAnswer? {
        var groups: [String: (IPAnswer, Int)] = [:]
        for x in a { groups[x.ip + "|" + x.country.uppercased(), default: (x, 0)].1 += 1 }
        let ok = groups.values.filter { $0.1 >= max(1, minAgree) }
        return ok.count == 1 ? ok[0].0 : nil
    }

    /// Allow list for the global leak signals (IPv6 / route), which the Guard cannot evaluate per
    /// app: the union of the protected apps' effective allow lists. Known limit: with differing
    /// per-app rules a route/IPv6 exit allowed only for another app is not reported as a leak.
    static func leakAllow(_ c: Config) -> AllowList {
        let ids = AppCatalog.appIDs(in: c)
        guard !ids.isEmpty else { return c.allow }
        var out = AllowList()
        for id in ids {
            let a = effectiveAllow(for: id, in: c)
            for ip in a.ips where !out.ips.contains(ip) { out.ips.append(ip) }
            for cc in a.countries where !out.countries.contains(cc) { out.countries.append(cc) }
        }
        return out
    }

    /// First-run prompt: some protected app has an empty effective allow list, so it can never
    /// pass a check (empty list allows nothing). Nothing is allowed automatically.
    public static func needsAllowSetup(_ c: Config) -> Bool {
        AppCatalog.appIDs(in: c).contains { id in
            let a = effectiveAllow(for: id, in: c)
            return a.ips.isEmpty && a.countries.isEmpty
        }
    }
}
