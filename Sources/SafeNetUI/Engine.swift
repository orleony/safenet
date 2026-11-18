import Foundation
import SafeNetCore

/// Everything the UI shows about the protection, in one value (published on every change).
public struct EngineStatus: Equatable {
    public var state: GuardState = .ok
    public var frozenApps: Set<String> = []
    public var releasedApps: Set<String> = []
    public var freezeFailedApps: Set<String> = []
    /// Apps matching only protected system processes (running unrestricted; subset of freezeFailedApps).
    public var unprotectableApps: Set<String> = []
    /// Apps that should be frozen but have no running process («не запущено»).
    public var notRunningApps: Set<String> = []
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
    /// Fetches IP answers from the services of `mode` (`IPServiceSet`); must call back on the
    /// engine's queue (tests: synchronously).
    public var fetchAnswers: (IPFetchMode, @escaping ([IPAnswer]) -> Void) -> Void
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
    /// Number of cheap services asked by the periodic tick (caps the quorum of that tick).
    public var cheapServiceCount = 2
    /// The full fan-out runs at least this often while apps are protected (10 min).
    public var fullRefreshInterval: TimeInterval = 600
    /// Non-nil: nothing is written to disk (test mode without SAFENET_CONFIG_DIR would otherwise
    /// put the fake IP/country into the user's real config.yaml). Changes still apply in memory;
    /// the message is reported through `onNotice`.
    public var configWritesBlocked: String?

    public init(clock: Clock, freezer: Freezer, log: EventLog, store: ConfigStore,
                fetchAnswers: @escaping (IPFetchMode, @escaping ([IPAnswer]) -> Void) -> Void,
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
/// fresh FULL check; every `check_interval` (only while apps are protected) a CHEAP check (1.1.1.1
/// trace + api.country.is) that compares the IP only: when enough of them report the last
/// confirmed IP the last FULL answers (and their country) are kept, anything else (other IP, too
/// few answers, nothing confirmed yet) runs the full fan-out at once; the full fan-out also runs
/// every `fullRefreshInterval` (10 min); `Guard.tick()` every second (resume retries, catch-up
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
    /// Uptime of the last finished FULL fan-out (nil = none yet).
    private var lastFullAt: TimeInterval?
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
        guardian.adoptUnresolved(left)               // keep retrying them every tick

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

    /// Starts a FULL check now (all services; coalesced with one in flight). Used at start, on
    /// network change / wake / end of pause (through the Guard) and by "Проверить сейчас".
    public func checkNow() { check(.full) }

    private func check(_ mode: IPFetchMode) {
        guard running else { return }
        if checking { recheck = true; return }      // the follow-up is always a full check
        checking = true
        let snap = snapshot ?? deps.snapshotNow()
        snapshot = snap
        let gen = netGen
        if !snap.online { finish([], gen, .full); return }
        deps.fetchAnswers(mode) { [weak self] a in self?.finish(a, gen, mode) }
    }

    private func finish(_ answers: [IPAnswer], _ gen: Int, _ mode: IPFetchMode) {
        checking = false
        guard running else { return }
        if gen != netGen {                           // network changed meanwhile: stale answers
            recheck = false
            check(.full)
            return
        }
        if mode == .cheap {
            guard Engine.cheapConfirms(answers, last: lastAnswers, minAgree: config.minAgree,
                                       cheapCount: deps.cheapServiceCount) else {
                check(.full)                         // changed IP, too few answers, nothing confirmed
                return
            }
            // Unchanged IP: keep the last FULL answers (country included) and re-evaluate (DNS,
            // routes, trusted network may have changed).
        } else {
            let before = Engine.confirmed(Engine.quorumAnswers(lastAnswers), minAgree: config.minAgree)
            lastAnswers = answers
            lastFullAt = deps.clock.uptime
            let now = Engine.confirmed(Engine.quorumAnswers(answers), minAgree: config.minAgree)
            if let b = before, let n = now, b.ip != n.ip {
                // Local history only; the address itself is not written (and never notified).
                deps.log.append(Event(date: deps.clock.now, kind: .ipChanged, app: nil, detail: ""))
            }
        }
        evaluateAndApply()
        if recheck { recheck = false; check(.full) }
    }

    /// Periodic tick: nothing at all without protected apps; a full fan-out when the last one is
    /// older than `fullRefreshInterval`; else the cheap check.
    private func pollTick() {
        guard running, !AppCatalog.appIDs(in: config).isEmpty else { return }
        let due = lastFullAt.map { deps.clock.uptime - $0 >= deps.fullRefreshInterval } ?? true
        check(due ? .full : .cheap)
    }

    private func evaluateAndApply() {
        let snap = snapshot ?? deps.snapshotNow()
        let wantDNS = config.dnsCheck != .off && snap.hasTunnel
        var s = NetworkSampler.makeSample(snapshot: snap, answers: lastAnswers, routes: routesActive ? routes : nil,
                                          resolvers: wantDNS ? deps.resolvers() : nil,
                                          allow: config.allow, config: config)
        // Display / journal flags: a leak for at least one protected app (each app is judged
        // with its own allow list by `evaluate` through `leakInputs`).
        if let li = s.observation.leakInputs {
            let lists = Engine.protectedAllowLists(config)
            s.observation.ipv6Leak = li.checkIPv6 && lists.contains { detectIPv6Leak(answers: li.ipv6Answers, allow: $0) }
            s.observation.routeLeak = li.checkRoutes && lists.contains { detectRouteLeak(li.routes, allow: $0) }
        }
        s.observation.ips = Engine.quorumAnswers(lastAnswers)
        lastSample = s
        lastCheck = deps.clock.now
        guardian.apply(s.observation)
        publish()
    }

    // MARK: Actions

    /// What `updateConfig` did with the change (the CLI reports it; the UI learns the same through
    /// `onNotice` / `onConfigError`).
    public enum UpdateResult: Equatable {
        /// Engine stopped or the mutation changed nothing.
        case unchanged
        /// Written to config.yaml and in effect.
        case saved
        /// Test mode without SAFENET_CONFIG_DIR: nothing written; the change is in effect until exit.
        case refused(String)
        /// The file could not be written (or the broken file could not be backed up first): in effect
        /// until restart only.
        case notSaved(String)
        /// The change would make the config invalid: refused, nothing changed.
        case invalid(String)
    }

    /// No-op after `shutdown()` (a queued action must not re-protect / re-freeze while exiting).
    @discardableResult
    public func updateConfig(_ mutate: (inout Config) -> Void) -> UpdateResult {
        guard running else { return .unchanged }
        var c = config
        mutate(&c)
        guard c != config else { return .unchanged }
        do { try c.validate() } catch {
            let m = "Изменение отклонено: \(Engine.safeDescription(error))"
            onConfigError?(m)
            return .invalid(m)
        }
        var result = UpdateResult.saved
        if let msg = deps.configWritesBlocked {
            onNotice?(msg)
            result = .refused(msg)
        } else if fileBroken && !backupBrokenFile() {
            let m = "config.yaml с ошибкой не перезаписан: не удалось сохранить его копию. Изменение действует до перезапуска."
            onConfigError?(m)
            result = .notSaved(m)
        } else {
            do {
                try deps.store.save(c)
                fileBroken = false
                Engine.saveLastGood(c, deps.store)
                onConfigHealthy?()
            } catch {
                let m = "не удалось сохранить config.yaml (\(Engine.safeDescription(error)))"
                onConfigError?(m)
                result = .notSaved(m)
            }
        }
        apply(config: c)
        return result
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

    /// Presets are matched case-insensitively (as `AppCatalog.preset` and the UI do) and stored
    /// under their canonical id; custom app names exactly.
    public func toggleApp(_ id: String) {
        updateConfig { c in
            let custom = c.customApps.contains { $0.name == id }
            let canon = custom ? id : (AppCatalog.preset(id)?.id ?? id)
            let customNames = Set(c.customApps.map { $0.name })
            let exact = custom || AppCatalog.preset(id) == nil
            let same: (String) -> Bool = { s in
                exact ? s == id : (AppCatalog.preset(s)?.id == canon && !customNames.contains(s))
            }
            if c.apps.contains(where: same) { c.apps.removeAll(where: same) } else { c.apps.append(canon) }
        }
    }

    private func apply(config c: Config) {
        guard running else { return }
        let oldInterval = config.checkInterval
        let wasActive = routesActive
        let hadApps = !AppCatalog.appIDs(in: config).isEmpty
        config = c
        guardian.updateConfig(c)
        if oldInterval != c.checkInterval { schedulePoll() }
        if wasActive != routesActive { updateRouteSchedule(after: 0) }
        onConfig?(c)
        if lastSample != nil { evaluateAndApply() } else { publish() }
        // First protected app after a time without polling: the last answers may be old.
        if !hadApps && !AppCatalog.appIDs(in: c).isEmpty { checkNow() }
    }

    // MARK: Timers

    private func schedulePoll() {
        pollTimer?.cancel()
        guard running else { return }
        pollTimer = deps.clock.schedule(after: max(1, config.checkInterval)) { [weak self] in
            self?.pollTick(); self?.schedulePoll()
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
            if gen == self.netGen {
                self.routes = r
                // Re-evaluate with the new route data; no IP fan-out just for a probe (quotas).
                if self.lastSample != nil && !self.checking { self.evaluateAndApply() } else { self.checkNow() }
            }
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
        s.unprotectableApps = guardian.unprotectableApps
        s.notRunningApps = guardian.notRunningApps
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

    /// Cheap periodic check (IP only; GeoIP countries differ between services): true when the
    /// last FULL answers confirm an IP, every IPv4 cheap answer equals it, every IPv6 cheap
    /// answer equals an IPv6 address the full check saw (same exit over IPv6), and at least
    /// `min(min_agree, cheapCount)` cheap answers match (at least one of them the IPv4 one).
    /// Never confirms a NEW IP: anything else returns false and the full fan-out decides.
    static func cheapConfirms(_ cheap: [IPAnswer], last: [IPAnswer], minAgree: Int, cheapCount: Int) -> Bool {
        guard let conf = confirmed(quorumAnswers(last), minAgree: minAgree) else { return false }
        let known6 = Set(last.filter { $0.ip.contains(":") }.map { $0.ip })
        var v4 = 0, v6 = 0
        for a in cheap {
            if a.ip.contains(":") && a.ip != conf.ip {
                guard known6.contains(a.ip) else { return false }
                v6 += 1
            } else {
                guard a.ip == conf.ip else { return false }
                v4 += 1
            }
        }
        let need = min(max(1, minAgree), max(1, cheapCount))
        return v4 >= 1 && v4 + v6 >= need
    }

    static func confirmed(_ a: [IPAnswer], minAgree: Int) -> IPAnswer? {
        var groups: [String: (IPAnswer, Int)] = [:]
        for x in a { groups[x.ip + "|" + x.country.uppercased(), default: (x, 0)].1 += 1 }
        let ok = groups.values.filter { $0.1 >= max(1, minAgree) }
        return ok.count == 1 ? ok[0].0 : nil
    }

    /// Display only (deep check rows): the union of the protected apps' effective allow lists.
    /// The protection itself judges every app with its own list (`LeakInputs`).
    static func leakAllow(_ c: Config) -> AllowList {
        var out = AllowList()
        for a in protectedAllowLists(c) {
            for ip in a.ips where !out.ips.contains(ip) { out.ips.append(ip) }
            for cc in a.countries where !out.countries.contains(cc) { out.countries.append(cc) }
        }
        return out
    }

    /// Effective allow lists of the protected apps (the common list when none is protected).
    static func protectedAllowLists(_ c: Config) -> [AllowList] {
        let ids = AppCatalog.appIDs(in: c)
        return ids.isEmpty ? [c.allow] : ids.map { effectiveAllow(for: $0, in: c) }
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
