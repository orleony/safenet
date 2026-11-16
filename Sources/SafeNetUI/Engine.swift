import Foundation
import SafeNetCore

/// Everything the UI shows about the protection, in one value (published on every change).
public struct EngineStatus: Equatable {
    public var state: GuardState = .ok
    public var frozenApps: Set<String> = []
    public var releasedApps: Set<String> = []
    public var freezeFailedApps: Set<String> = []
    /// Apps actually closed (not every app when the overall state is `.closed`).
    public var closedApps: Set<String> = []
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
    /// Non-nil: nothing is written to disk (test mode without SAFENET_CONFIG_DIR would otherwise
    /// put the fake IP/country into the user's real config.yaml). Changes still apply in memory;
    /// the message is reported through `onNotice`.
    public var configWritesBlocked: String?

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
    /// config.yaml was loaded (hot reload) or saved successfully: earlier config errors are over.
    public var onConfigHealthy: (() -> Void)?
    /// Informational message for the window (no notification), e.g. a refused write in test mode.
    public var onNotice: ((String) -> Void)?

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
    /// config.yaml on disk failed to load (at launch or on hot reload): the first save keeps a
    /// `config.broken-<time>.yaml` copy before overwriting it, so the user's edit is not lost.
    private var fileBroken = false

    public init(deps: EngineDeps) {
        self.deps = deps
        var err: String?
        config = Engine.loadOrCreate(deps.store, writesBlocked: deps.configWritesBlocked != nil, error: &err)
        startupError = err
        fileBroken = FileManager.default.fileExists(atPath: deps.store.url.path) && (try? deps.store.load()) == nil
        guardian = Guard(config: config, freezer: deps.freezer, clock: deps.clock, log: deps.log)
        guardian.callbackQueue = deps.queue
    }

    /// Last config that loaded and validated, kept next to config.yaml. Used at launch when
    /// config.yaml is broken (the spec's "работа на старых настройках" needs something old).
    static func lastGoodStore(_ store: ConfigStore) -> ConfigStore {
        ConfigStore(url: store.url.deletingLastPathComponent().appendingPathComponent("config.last-good.yaml"))
    }

    /// - missing file: defaults, written to disk (first run);
    /// - valid file: used, and copied to the last-good file;
    /// - broken / empty file: the last-good copy, else defaults (nothing protected) with a
    ///   prominent error. The broken file is NEVER overwritten: the user fixes it.
    static func loadOrCreate(_ store: ConfigStore, writesBlocked: Bool, error: inout String?) -> Config {
        if !FileManager.default.fileExists(atPath: store.url.path) {
            if !writesBlocked {
                do { try store.save(.default) } catch let e { error = "не удалось создать config.yaml (\(safeDescription(e)))" }
            }
            return .default
        }
        do {
            let c = try store.load()
            if !writesBlocked { saveLastGood(c, store) }
            return c
        } catch let e {
            let why = safeDescription(e)
            let lg = lastGoodStore(store)            // load() of a missing file returns defaults: check first
            if FileManager.default.fileExists(atPath: lg.url.path), let c = try? lg.load() {
                error = "config.yaml не загружен (\(why)). Используются прежние настройки из config.last-good.yaml; исправьте файл."
                return c
            }
            error = "config.yaml не загружен (\(why)), прежних настроек нет: ничего не защищено до исправления файла!"
            return .default
        }
    }

    static func saveLastGood(_ c: Config, _ store: ConfigStore) {
        try? lastGoodStore(store).save(c)          // atomic; best effort
    }

    /// Error text safe for the UI and notifications: config/YAML errors as they are (they hold
    /// no paths), anything else only as domain + code (Cocoa errors embed the file path and
    /// thereby the user name).
    public static func safeDescription(_ e: Error) -> String {
        if let c = e as? ConfigError { return c.description }
        if let y = e as? YAMLError { return y.description }
        let n = e as NSError
        return "ошибка \(n.domain) \(n.code)"
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
                case .success(let c):
                    guard let self = self, self.running else { return }
                    self.fileBroken = false
                    self.onConfigHealthy?()
                    if self.deps.configWritesBlocked == nil { Engine.saveLastGood(c, self.deps.store) }
                    self.apply(config: c)
                case .failure(let e):
                    guard let self = self, self.running else { return }
                    self.fileBroken = true
                    self.onConfigError?("config.yaml не загружен (\(Engine.safeDescription(e))). Работаю на прежних настройках.")
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

    /// No-op after `shutdown()` (a queued action must not re-protect / re-freeze while exiting).
    public func updateConfig(_ mutate: (inout Config) -> Void) {
        guard running else { return }
        var c = config
        mutate(&c)
        guard c != config else { return }
        if let msg = deps.configWritesBlocked {
            onNotice?(msg)
        } else if fileBroken && !backupBrokenFile() {
            onConfigError?("config.yaml с ошибкой не перезаписан: не удалось сохранить его копию. Изменение действует до перезапуска.")
        } else {
            do {
                try deps.store.save(c)
                fileBroken = false
                Engine.saveLastGood(c, deps.store)
                onConfigHealthy?()
            } catch {
                onConfigError?("не удалось сохранить config.yaml (\(Engine.safeDescription(error)))")
            }
        }
        apply(config: c)
    }

    public var isRunning: Bool { running }

    /// Event history (thread-safe; readable from any queue).
    public var log: EventLog { deps.log }

    /// Copies the broken config.yaml to `config.broken-<yyyyMMdd-HHmmss>.yaml` next to it and tells
    /// the user (file name only, no path). False when the copy could not be written.
    private func backupBrokenFile() -> Bool {
        let src = deps.store.url
        guard FileManager.default.fileExists(atPath: src.path) else { return true }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: deps.clock.now)
        let dir = src.deletingLastPathComponent()
        var name = "config.broken-\(stamp).yaml", n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            name = "config.broken-\(stamp)-\(n).yaml"; n += 1
        }
        do {
            try FileManager.default.copyItem(at: src, to: dir.appendingPathComponent(name))
        } catch {
            return false
        }
        onNotice?("config.yaml с ошибкой сохранён как \(name) (в той же папке), а настройки записаны заново.")
        return true
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
        guard running else { return }
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
        s.closedApps = guardian.closedApps
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
