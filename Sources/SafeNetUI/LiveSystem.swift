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

    private var monitor: NetworkMonitor?
    private let watchdog: WatchdogLauncher
    private var signalSources: [DispatchSourceSignal] = []
    private var observers: [NSObjectProtocol] = []
    private var stopped = false

    public init(environment env: [String: String] = ProcessInfo.processInfo.environment) {
        paths = AppPaths.from(environment: env)
        paths.createDirectory()
        testMode = TestMode.from(environment: env)
        let q = queue
        let freezer = Freezer(table: SystemProcessTable(), signaler: KillSignaler(), journal: paths.journal)
        let fetch: (@escaping ([IPAnswer]) -> Void) -> Void
        let probe: ([String], @escaping ([RouteResult]) -> Void) -> Void
        let runner = ProcessCommandRunner()
        var snapshotNow: () -> NetSnapshot = {
            var s = SnapshotBuilder.build(interfaces: SnapshotBuilder.systemInterfaces(), pathSatisfied: true,
                                          proxy: SnapshotBuilder.systemProxy(), runner: runner)
            s.online = s.interface != nil          // no default route = offline (never assume online)
            return s
        }
        if let t = testMode {
            NSLog("SafeNet: TEST MODE (SAFENET_FAKE_IP=%@, offline=%@)",
                  t.fakeAnswer.map { "\($0.ip),\($0.country)" } ?? "-", t.offline ? "yes" : "no")
            let ans = t.fakeAnswer, off = t.offline
            fetch = { cb in q.async { cb(off || ans == nil ? [] : Array(repeating: ans!, count: 4)) } }
            probe = { hosts, cb in
                q.async {
                    cb(hosts.map { RouteResult(host: $0, ip: ans?.ip, country: ans?.country,
                                               error: off || ans == nil ? "test mode offline" : nil) })
                }
            }
            if off {
                snapshotNow = { NetSnapshot(online: false, hasTunnel: false, gatewayIP: nil, gatewayMAC: nil, proxy: nil) }
            }
        } else {
            // Services are created once and reused (each HTTPIPService owns a URLSession).
            let services: [IPService] = (HTTPIPService.defaults + [HTTPIPService.ipv6Only]).map { HTTPIPService(spec: $0) }
            let checker = IPChecker(services: services, timeout: 6)
            fetch = { cb in Task { let a = await checker.check(); q.async { cb(a) } } }
            let rp = RouteProbe()
            probe = { hosts, cb in Task { let r = await rp.check(hosts: hosts); q.async { cb(r) } } }
        }
        let deps = EngineDeps(clock: SystemClock(queue: q), freezer: freezer, log: EventLog(url: paths.events),
                              store: ConfigStore(url: paths.config), fetchAnswers: fetch, probeRoutes: probe,
                              resolvers: { currentDNSResolvers(runner: runner) }, snapshotNow: snapshotNow, queue: q)
        engine = Engine(deps: deps)
        watchdog = WatchdogLauncher(journal: paths.journal)

        let offlineSource: ((Bool) -> NetSnapshot)? = testMode?.offline == true ? { _ in snapshotNow() } : nil
        monitor = NetworkMonitor(snapshotSource: offlineSource) { [weak self] snap in
            self?.queue.async { self?.engine.networkChanged(snap) }
        }
    }

    /// Main thread. Starts the watchdog first (it must exist before anything is frozen).
    public func start() {
        installSignalHandlers()
        watchdog.start()
        engine.onStatus = { [weak self] s in DispatchQueue.main.async { self?.onStatus?(s) } }
        engine.onConfig = { [weak self] c in DispatchQueue.main.async { self?.onConfig?(c) } }
        engine.onConfigError = { [weak self] e in DispatchQueue.main.async { self?.onConfigError?(e) } }
        queue.async { [weak self] in
            guard let self = self else { return }
            self.engine.start()
            self.monitor?.start()
        }
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.engine.willSleep() }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.engine.didWake(); self?.monitor?.refresh() }
        })
    }

    /// Runs `body` on the engine queue (UI actions).
    public func perform(_ body: @escaping (Engine) -> Void) {
        queue.async { [weak self] in if let e = self?.engine { body(e) } }
    }

    /// Main thread. Idempotent. Resumes every frozen process before returning.
    public func shutdown() {
        guard !stopped else { return }
        stopped = true
        watchdog.stop()
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
