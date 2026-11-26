import Foundation
import AppKit
import SafeNetCore

/// Production wiring of the `Engine`: real IP services / route probe / network monitor on one
/// serial queue, sleep/wake notifications, the watchdog child and termination signals.
/// Status and config updates are delivered on the main queue.
public final class LiveSystem {
    public let paths: AppPaths
    public let testMode: TestMode?
    public let queue = DispatchQueue(label: "safenet.engine")
    public let engine: Engine
    public var onStatus: ((EngineStatus) -> Void)?
    public var onConfig: ((Config) -> Void)?
    public var onConfigError: ((String) -> Void)?
    public var onConfigHealthy: (() -> Void)?
    public var onNotice: ((String) -> Void)?
    /// Test mode without SAFENET_CONFIG_DIR: settings are not saved (the real config stays clean).
    public let configReadOnly: Bool
    public static let readOnlyMessage = "Тестовый режим: настройки не сохраняются"

    private var monitor: NetworkMonitor?
    /// Deep check ("Проверка" tab): the same endpoints the engine uses, nothing else.
    private let deepRunner: (@escaping (DeepCheckData) -> Void) -> Void
    private let watchdog: WatchdogLauncher
    private var signalSources: [DispatchSourceSignal] = []
    private var observers: [NSObjectProtocol] = []
    private var stopped = false
    private var ipc: IPCServer?
    /// Held for the whole life of the app (released by the kernel at exit).
    private let instanceLock: InstanceLock
    /// Shown once the window is up (the lock file could not be opened).
    private let lockProblem: String?

    /// Fills in the country of every IPv4 answer from `geo` (one lookup per distinct address,
    /// remembered). `lookUp` false (cheap tick): only remembered countries, no database request.
    /// IPv6 answers keep the country their own service gave. Unknown = "".
    static func withCountries(_ answers: [IPAnswer], geo: GeoResolver, lookUp: Bool) async -> [IPAnswer] {
        var countries: [String: String] = [:]
        for ip in Set(answers.filter { !$0.ip.contains(":") }.map { $0.ip }) {
            let e = lookUp ? await geo.country(of: ip) : geo.cached(ip)
            countries[ip] = e?.country ?? ""
        }
        return answers.map { a in a.ip.contains(":") ? a : IPAnswer(ip: a.ip, country: countries[a.ip] ?? "") }
    }

    public init(environment env: [String: String] = ProcessInfo.processInfo.environment) {
        paths = AppPaths.from(environment: env)
        paths.createDirectory()
        // Single instance, before the Freezer touches the journal. Busy = another SafeNet runs, or
        // the watchdog of a just-quit one is still resuming its apps (up to ~10 s): wait for it.
        instanceLock = InstanceLock(url: InstanceLock.path(forJournal: paths.journal))
        switch instanceLock.acquire(timeout: InstanceLock.appWait) {
        case .acquired: lockProblem = nil
        case .busy: LiveSystem.refuseSecondInstance()
        case .unavailable(let e):
            // Not "already running": the lock file cannot be opened (support dir unwritable?).
            // Fail safe: protection still starts (as before the lock existed); the user is told.
            NSLog("SafeNet: safenet.lock unavailable (errno %d); single-instance check skipped", e)
            lockProblem = "Не удалось открыть safenet.lock (ошибка \(e)): проверка «второй экземпляр» отключена. Не запускайте SafeNet дважды."
        }
        testMode = TestMode.from(environment: env)
        configReadOnly = testMode != nil && (env["SAFENET_CONFIG_DIR"] ?? "").isEmpty
        let q = queue
        let freezer = Freezer(table: SystemProcessTable(), signaler: KillSignaler(), journal: paths.journal)
        let fetch: (IPFetchMode, [String], @escaping ([IPAnswer]) -> Void) -> Void
        let probe: ([String], @escaping ([RouteResult]) -> Void) -> Void
        let runner = ProcessCommandRunner()
        var snapshotNow: () -> NetSnapshot = {
            var s = SnapshotBuilder.build(interfaces: SnapshotBuilder.systemInterfaces(), pathSatisfied: true,
                                          proxy: SnapshotBuilder.systemProxy(), runner: runner)
            s.online = s.interface != nil          // no default route = offline (never assume online)
            return s
        }
        let deep: (@escaping (DeepCheckData) -> Void) -> Void
        var resetBackoff: () -> Void = {}
        let resolversNow: () -> [DNSResolver]? = { currentDNSResolvers(runner: runner) }
        if let t = testMode {
            NSLog("SafeNet: TEST MODE (SAFENET_FAKE_IP=%@, offline=%@)",
                  t.fakeAnswer.map { "\($0.ip),\($0.country)" } ?? "-", t.offline ? "yes" : "no")
            let ans = t.fakeAnswer, off = t.offline
            fetch = { mode, hosts, cb in
                let count = mode == .cheap ? hosts.filter { IPServiceSet.cheapHosts.contains($0) }.count : hosts.count
                q.async { cb(ans.map { off ? [] : Array(repeating: $0, count: count) } ?? []) }
            }
            probe = { hosts, cb in
                q.async {
                    cb(hosts.map { RouteResult(host: $0, ip: ans?.ip, country: ans?.country,
                                               error: off || ans == nil ? "test mode offline" : nil) })
                }
            }
            if off {
                snapshotNow = { NetSnapshot(online: false, hasTunnel: false, gatewayIP: nil, gatewayMAC: nil, proxy: nil) }
            }
            let snapFn = snapshotNow
            deep = { cb in
                DispatchQueue.global().async {
                    let r: ServiceResult.Outcome = off || ans == nil ? .failed("test mode offline") : .answer(ans!)
                    let svc = IPServiceSet.ipv4Hosts.map { ServiceResult(service: $0, outcome: r) }
                    let routes = URLSessionTraceFetcher.hosts.map {
                        RouteResult(host: $0, ip: ans?.ip, country: ans?.country, error: off || ans == nil ? "test mode offline" : nil)
                    }
                    var d = DeepCheckData(services: svc, ipv6: ServiceResult(service: "тестовый IPv6", outcome: .failed("test mode")),
                                          routes: routes, resolvers: resolversNow(), snapshot: snapFn(), finished: Date())
                    if let a = ans, !off {
                        d.geoIP = a.ip
                        d.geo = [GeoAnswer(source: "тестовая база", outcome: .success(a.country))]
                    }
                    cb(d)
                }
            }
        } else {
            // Services are created once and reused (each owns a URLSession and its backoff state).
            // Tiered (ruling R1): the periodic tick asks only the cheap address services; the
            // rest and the IPv6 one are asked in the full fan-out. Address services return the IP
            // only; its country comes from `GeoResolver` (first valid database, remembered per
            // address), so the quota-limited GeoIP databases are asked only when the IP changes.
            let v4 = IPServiceSet.makeServices().map { BackoffIPService($0) }
            let cheapSet = Set(IPServiceSet.cheapHosts)
            let six = BackoffIPService(HTTPIPService(spec: HTTPIPService.ipv6Only))
            let geo = GeoResolver(sources: HTTPGeoSource.defaults)
            resetBackoff = { (v4 + [six]).forEach { $0.reset() }; geo.resetPauses() }
            fetch = { mode, hosts, cb in
                let selected = Set(hosts)
                let services: [IPService] = v4.filter { selected.contains($0.name) && (mode == .full || cheapSet.contains($0.name)) }
                    + (mode == .full ? [six] : [])
                let checker = IPChecker(services: services, timeout: 6)
                Task {
                    let answers = await LiveSystem.withCountries(await checker.check(), geo: geo, lookUp: mode == .full)
                    q.async { cb(answers) }
                }
            }
            let rp = RouteProbe()
            probe = { hosts, cb in Task { let r = await rp.check(hosts: hosts); q.async { cb(r) } } }
            // Deep check: its own unwrapped address services, so it neither feeds nor obeys the
            // shared backoff; every GeoIP database is asked about the majority address.
            let deepV4 = IPChecker(services: IPServiceSet.makeServices(), timeout: 6)
            let deep6 = IPChecker(services: [HTTPIPService(spec: HTTPIPService.ipv6Only)], timeout: 6)
            let snapFn = snapshotNow
            deep = { cb in
                Task.detached {
                    async let each = deepV4.checkEach()
                    async let sixEach = deep6.checkEach()
                    async let routes = rp.check(hosts: URLSessionTraceFetcher.hosts)
                    let services = await each
                    let majority = DeepCheck.majorityIP(services.compactMap { $0.answer })
                    var geoAnswers: [GeoAnswer] = []
                    if let ip = majority { geoAnswers = await geo.lookupAll(ip) }
                    let resolvers = resolversNow(), snap = snapFn()
                    var d = DeepCheckData(services: services, ipv6: await sixEach.first, routes: await routes,
                                          resolvers: resolvers, snapshot: snap, finished: Date())
                    d.geo = geoAnswers
                    d.geoIP = majority
                    cb(d)
                }
            }
        }
        let deps = EngineDeps(clock: SystemClock(queue: q), freezer: freezer, log: EventLog(url: paths.events),
                              store: ConfigStore(url: paths.config), fetchAnswers: fetch, probeRoutes: probe,
                              resolvers: resolversNow, snapshotNow: snapshotNow, queue: q)
        deepRunner = deep
        var d = deps
        d.resetBackoff = resetBackoff
        if configReadOnly {
            d.configWritesBlocked = LiveSystem.readOnlyMessage
            NSLog("SafeNet: TEST MODE without SAFENET_CONFIG_DIR: config.yaml is read-only for this run")
        }
        engine = Engine(deps: d)
        watchdog = WatchdogLauncher(journal: paths.journal)

        let offlineSource: ((Bool) -> NetSnapshot)? = testMode?.offline == true ? { _ in snapshotNow() } : nil
        monitor = NetworkMonitor(snapshotSource: offlineSource) { [weak self] snap in
            self?.queue.async { self?.engine.networkChanged(snap) }
        }
    }

    /// Another instance owns the journal: say so and exit WITHOUT touching it.
    private static func refuseSecondInstance() -> Never {
        NSLog("SafeNet: another instance is running (safenet.lock busy); exiting")
        FileHandle.standardError.write(Data("SafeNet уже запущен.\n".utf8))
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "SafeNet уже запущен"
        a.informativeText = "Значок SafeNet уже есть в строке меню. Второй экземпляр закрывается."
        a.addButton(withTitle: "OK")
        a.runModal()
        exit(0)
    }

    /// Main thread. Starts the watchdog first (it must exist before anything is frozen).
    public func start() {
        installSignalHandlers()
        watchdog.start()
        engine.onStatus = { [weak self] s in DispatchQueue.main.async { self?.onStatus?(s) } }
        engine.onConfig = { [weak self] c in DispatchQueue.main.async { self?.onConfig?(c) } }
        engine.onConfigError = { [weak self] e in DispatchQueue.main.async { self?.onConfigError?(e) } }
        engine.onNotice = { [weak self] e in DispatchQueue.main.async { self?.onNotice?(e) } }
        engine.onConfigHealthy = { [weak self] in DispatchQueue.main.async { self?.onConfigHealthy?() } }
        if let m = lockProblem { DispatchQueue.main.async { [weak self] in self?.onNotice?(m) } }
        queue.async { [weak self] in
            guard let self = self else { return }
            self.engine.start()
            self.monitor?.start()
        }
        startIPC()
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.engine.willSleep() }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.engine.didWake(); self?.monitor?.refresh() }
        })
    }

    /// CLI socket (`SafeNetApp status`, ...). A failure only costs the CLI: protection goes on.
    private func startIPC() {
        let service = CLIService(
            perform: { [weak self] body in self?.perform(body) }, paths: paths, testMode: testMode,
            configReadOnly: configReadOnly,
            openPanel: { done in DispatchQueue.main.async { PanelOpener.openFromCLI(done: done) } },
            version: AppState.version)
        let path = paths.socketPath
        let server = IPCServer(path: path, strictDirectory: path != paths.dir.appendingPathComponent("safenet.sock").path,
                               handler: { service.handle($0, reply: $1) })
        do {
            try server.start()
            ipc = server
        } catch {
            NSLog("SafeNet: CLI socket not started: %@", "\(error)")
        }
    }

    /// Deep check on demand (IP services one by one, IPv6, DNS, route to the AI hosts). Calls back
    /// on a background queue.
    public func deepCheck(_ done: @escaping (DeepCheckData) -> Void) { deepRunner(done) }

    /// Runs `body` on the engine queue (UI actions).
    public func perform(_ body: @escaping (Engine) -> Void) {
        // Dropped after shutdown: a queued action must not re-protect / re-freeze while exiting.
        queue.async { [weak self] in if let e = self?.engine, e.isRunning { body(e) } }
    }

    /// Main thread. Idempotent. Resumes every frozen process before returning.
    public func shutdown() {
        guard !stopped else { return }
        stopped = true
        watchdog.stop()
        ipc?.stop(); ipc = nil
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers = []
        monitor?.stop()
        let left = queue.sync { engine.shutdown(deadline: 2) }
        if !left.isEmpty { NSLog("SafeNet: %d processes still stopped at exit; the watchdog retries", left.count) }
        // The watchdog notices our exit and retries whatever is left in the journal.
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.shutdown()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }
}

/// Keeps a watchdog child running: the same binary started DIRECTLY by this process (posix_spawn
/// through Foundation.Process, no shell, no launchd) as `--watchdog <ourPID> <journal>`. It is
/// restarted (with backoff) whenever it dies while we are running.
final class WatchdogLauncher {
    private let journal: URL
    private let lock = NSLock()
    private var process: Process?
    private var stopping = false
    private var backoff: TimeInterval = 1

    init(journal: URL) { self.journal = journal }

    func start() {
        lock.lock(); stopping = false; lock.unlock()
        spawn()
    }

    /// Stops restarting. The child is left alone: it exits by itself once we are gone, after
    /// resuming anything still journaled.
    func stop() { lock.lock(); stopping = true; lock.unlock() }

    private func spawn() {
        lock.lock(); defer { lock.unlock() }
        guard !stopping, let exe = Bundle.main.executableURL else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--watchdog", "\(getpid())", journal.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let started = Date()
        p.terminationHandler = { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock()
            let again = !self.stopping
            // Quick deaths back off up to 30 s; a long-lived child resets the backoff.
            self.backoff = Date().timeIntervalSince(started) > 60 ? 1 : min(self.backoff * 2, 30)
            let delay = self.backoff
            self.lock.unlock()
            if again {
                NSLog("SafeNet: watchdog exited, restarting in %.0f s", delay)
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in self?.spawn() }
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            NSLog("SafeNet: cannot start watchdog: %@", "\(error)")
            let delay = min(backoff * 2, 30); backoff = delay
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in self?.spawn() }
        }
    }
}
