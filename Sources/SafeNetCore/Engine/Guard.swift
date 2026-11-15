import Foundation

/// Aggregate protection state shown in the UI.
///
/// Aggregation rule (precedence top to bottom):
///  1. `.paused(until:)`  the user paused protection (all apps resumed, nothing is frozen);
///  2. `.frozen(...)`     at least one app is frozen. `since` = earliest freeze start among frozen
///                        apps; `deadline` = earliest close deadline among them (nil when none has a
///                        countdown: offline, or `keep_frozen` after the timeout); `reason` = reason
///                        of the app owning that earliest deadline (else of the earliest frozen app,
///                        ties broken by config order);
///  3. `.closed(date)`    no app is frozen, and at least one app was closed (timeout or "close now")
///                        and has not had a passing check since; date = latest close;
///  4. `.ok`              everything else, including apps released by `on_timeout: resume`
///                        (see `releasedApps`).
public enum GuardState: Equatable {
    case ok
    case frozen(since: Date, reason: Reason, deadline: Date?)
    case closed(Date)
    case paused(until: Date)
}

/// Kill-switch state machine. Decides PER APP (each app's effective allow list and grace),
/// drives the `Freezer`, runs the close countdown and logs history events.
///
/// Rules (spec "Решения по безопасности"):
///  - any uncertainty freezes; a close happens only after the app's full grace period, and the
///    countdown is discarded as soon as a check passes;
///  - offline freezes (when `block_when_offline`) but never closes: no countdown runs offline, a
///    running one is suspended and restarts from full grace once the network is back;
///  - a route leak is an ordinary freeze with countdown; "pause" is only the user's button;
///  - sleep: countdowns are cancelled in `willSleep`; `didWake` restarts them from full grace and
///    requests a fresh check.
///
/// Threading: every entry point runs under one lock. The Freezer is called with that lock held;
/// this is safe because the Freezer has no callbacks and never calls back into the Guard.
/// Callbacks (`onChange`, `onAllowIP`, `onCheckRequested`) and closing (`runClose`) run after the
/// lock is released, in order: synchronously on the calling thread, or, when `callbackQueue` is
/// set, enqueued on it (enqueued while still holding the lock, so their order is preserved).
public final class Guard {
    private struct AppStatus {
        enum Phase: Equatable { case ok, frozen, closed, released }
        var phase: Phase = .ok
        var since = Date.distantPast
        var reason: Reason = .unconfirmed
        var deadline: Date?
        /// `keep_frozen` timeout reached: stays frozen without a new countdown until a pass.
        var timedOut = false
        var closedAt: Date?
        /// Processes stopped on behalf of this app (roots and descendants).
        var procs: [Int32: ProcInfo] = [:]
        /// A `frozen` event was logged for this freeze episode (only once processes were stopped).
        var loggedFrozen = false
    }

    private let lock = NSLock()
    private var config: Config
    private let freezer: Freezer
    private let clock: Clock
    private let log: EventLog

    private var apps: [String: AppStatus] = [:]
    /// Pids whose resume was requested but not confirmed by the Freezer; retried every tick.
    private var pending: Set<Int32> = []
    private var pendingInfo: [Int32: ProcInfo] = [:]
    private var pausedUntil: Date?
    private var pauseTimer: Cancellable?
    private var pauseGen = 0
    private var deadlineTimer: Cancellable?
    private var timerGen = 0
    private var sleeping = false
    private var lastObservation: Observation?
    private var lastConfirmedIP: String?
    private var lastLeaks: Set<String> = []
    private var publishedState: GuardState = .ok
    private var publishedFrozen: Set<String> = []
    private var effects: [() -> Void] = []

    private var _onChange: ((GuardState) -> Void)?
    private var _onAllowIP: ((String) -> Void)?
    private var _onCheckRequested: (() -> Void)?
    private var _callbackQueue: DispatchQueue?
    private var _runClose: ([ProcInfo], TimeInterval) -> Void

    /// Fired after every change of `state` or `frozenApps`.
    public var onChange: ((GuardState) -> Void)? {
        get { locked { _onChange } } set { locked { _onChange = newValue } }
    }
    /// "Allow current IP": receives the confirmed IP; the owner appends it to the allow list and
    /// calls `updateConfig`. The Guard never writes the config itself.
    public var onAllowIP: ((String) -> Void)? {
        get { locked { _onAllowIP } } set { locked { _onAllowIP = newValue } }
    }
    /// The Guard wants a fresh network check now (wake, network change, end of pause).
    public var onCheckRequested: (() -> Void)? {
        get { locked { _onCheckRequested } } set { locked { _onCheckRequested = newValue } }
    }
    /// Where callbacks run; nil = synchronously on the calling thread after the lock is released.
    public var callbackQueue: DispatchQueue? {
        get { locked { _callbackQueue } } set { locked { _callbackQueue = newValue } }
    }
    /// How closing is performed (tests replace it with a synchronous version).
    var runClose: ([ProcInfo], TimeInterval) -> Void {
        get { locked { _runClose } } set { locked { _runClose = newValue } }
    }

    public init(config: Config, freezer: Freezer, clock: Clock, log: EventLog) {
        self.config = config; self.freezer = freezer; self.clock = clock; self.log = log
        self._runClose = { [freezer] procs, gentle in Task { await freezer.close(procs, gentle: gentle) } }
    }

    // MARK: Read-only state

    public var state: GuardState { locked { computeState() } }
    /// Apps currently frozen (decided per app).
    public var frozenApps: Set<String> { locked { frozenSet() } }
    /// Apps released by `on_timeout: resume`; protected again after the next passing check.
    public var releasedApps: Set<String> { locked { Set(apps.filter { $0.value.phase == .released }.keys) } }
    /// Pids still stopped although a resume was requested (retried on every tick).
    public var unresolvedPIDs: Set<Int32> { locked { pending } }

    // MARK: Entry points

    /// One network check result. Also a "tick": retries unresolved resumes and freezes newly
    /// started processes of frozen apps.
    public func apply(_ o: Observation) { perform { process(o) } }

    /// Maintenance without a new observation (retries, catch-up freezing).
    public func tick() { perform { reconcileProcesses() } }

    /// User pause: protection off, all apps resumed, protection returns after `d` (max 24 h).
    public func pause(for d: TimeInterval) {
        guard d.isFinite, d > 0 else { return }
        perform {
            let until = clock.now.addingTimeInterval(min(d, 86_400))
            pausedUntil = until
            for id in Array(apps.keys) { release(id) }
            apps = [:]
            record(.paused, nil, "pause")
            pauseTimer?.cancel()
            pauseGen += 1
            let gen = pauseGen
            pauseTimer = clock.schedule(after: until.timeIntervalSince(clock.now)) { [weak self] in
                self?.perform { self?.pauseFired(gen) }
            }
            reconcileProcesses()
        }
    }

    /// Ends a pause early ("resume protection"). No-op when not paused.
    public func resume() { perform { if pausedUntil != nil { endPause() } } }

    /// Offers the last CONFIRMED IP to `onAllowIP`. Nothing happens when none is confirmed.
    public func allowCurrentIP() {
        perform {
            guard let ip = lastConfirmedIP else { return }
            let cb = _onAllowIP
            effects.append { cb?(ip) }
        }
    }

    /// Pushes every running close countdown by `by` seconds.
    public func extend(by: TimeInterval) {
        guard by.isFinite, by > 0 else { return }
        perform {
            for id in ids() where apps[id]?.phase == .frozen {
                if let d = apps[id]?.deadline { apps[id]?.deadline = d.addingTimeInterval(by) }
            }
        }
    }

    /// Closes every frozen app now, whatever `on_timeout` says.
    public func closeNow() {
        perform {
            let now = clock.now
            for id in ids() where apps[id]?.phase == .frozen { closeApp(id, now, "closeNow") }
            reconcileProcesses()
        }
    }

    /// System network change (interface / route / proxy): instant freeze of every protected app,
    /// pending a fresh check. Ignored (only logged) while paused.
    public func networkChanged() {
        perform {
            record(.networkChanged, nil, "networkChanged")
            requestCheck()
            guard pausedUntil == nil else { return }
            let now = clock.now
            for id in ids() {
                let p = apps[id]?.phase ?? .ok
                if p == .ok || p == .released {
                    var a = AppStatus()
                    startFreeze(&a, id, .networkChanged, deadline: now.addingTimeInterval(grace(id)), now)
                    apps[id] = a
                }
            }
            reconcileProcesses()
        }
    }

    public func willSleep() { perform { sleeping = true } }

    public func didWake() {
        perform {
            sleeping = false
            let now = clock.now
            if let u = pausedUntil, now >= u { endPause() }
            for id in ids() where apps[id]?.phase == .frozen && apps[id]?.deadline != nil {
                apps[id]?.deadline = now.addingTimeInterval(grace(id))
            }
            requestCheck()
        }
    }

    /// New settings. Removed apps are unfrozen; the last observation is re-evaluated at once
    /// (e.g. a newly allowed country resumes apps). Running countdowns keep their deadline; a
    /// changed grace applies to the next freeze.
    public func updateConfig(_ c: Config) {
        perform {
            config = c
            let keep = Set(ids())
            for id in Array(apps.keys) where !keep.contains(id) { release(id); apps[id] = nil }
            if pausedUntil == nil, let o = lastObservation { process(o) } else { reconcileProcesses() }
        }
    }

    // MARK: Core (lock held)

    private func process(_ o: Observation) {
        lastObservation = o
        lastConfirmedIP = Guard.confirmedIP(o, minAgree: config.minAgree)
        logLeakEdges(o)
        guard pausedUntil == nil else { reconcileProcesses(); return }
        let now = clock.now
        for id in ids() {
            let v = evaluate(o, allow: effectiveAllow(for: id, in: config), minAgree: config.minAgree,
                             dnsCheck: config.dnsCheck)
            transition(id, v, now)
        }
        reconcileProcesses()
    }

    private func transition(_ id: String, _ v: Verdict, _ now: Date) {
        var a = apps[id] ?? AppStatus()
        switch (v, a.phase) {
        case (.ok, .frozen):
            if a.loggedFrozen { record(.resumed, id, "checkPassed") }
            release(id); a = AppStatus()
            apps[id] = nil
            return
        case (.ok, _):
            a = AppStatus()
        case (.offline, .ok):
            if config.blockWhenOffline { startFreeze(&a, id, .offline, deadline: nil, now) }
        case (.offline, .frozen):
            a.reason = .offline; a.deadline = nil          // countdown suspended, never closes offline
        case (.freeze(let r), .ok):
            startFreeze(&a, id, r, deadline: now.addingTimeInterval(grace(id)), now)
        case (.freeze(let r), .frozen):
            if a.deadline == nil && !a.timedOut { a.deadline = now.addingTimeInterval(grace(id)) }
            a.reason = r
        case (.offline, _), (.freeze, _):
            break                                          // closed / released: wait for a pass
        }
        apps[id] = a
    }

    private func startFreeze(_ a: inout AppStatus, _ id: String, _ r: Reason, deadline: Date?, _ now: Date) {
        let procs = a.procs
        a = AppStatus()
        a.phase = .frozen; a.since = now; a.reason = r; a.deadline = deadline; a.procs = procs
    }

    /// Moves the app's stopped processes to the resume queue (lock held; resumed in reconcile).
    private func release(_ id: String) {
        guard let a = apps[id] else { return }
        for (pid, p) in a.procs { pending.insert(pid); pendingInfo[pid] = p }
        apps[id]?.procs = [:]
    }

    /// Resume what must run, then freeze what must stop. Called at the end of every change.
    private func reconcileProcesses() {
        let engaged = ids().filter { let p = apps[$0]?.phase; return p == .frozen || p == .closed }
        if engaged.isEmpty {
            // Nothing should be stopped: resume everything (also leftovers). Retried each tick
            // until the Freezer reports empty. No catch-up freezing at all in this mode.
            if !pending.isEmpty || !freezer.frozenPIDs.isEmpty {
                let left = freezer.resumeAll()
                pending = left
                pendingInfo = pendingInfo.filter { left.contains($0.key) }
            }
            return
        }
        reclaimPending(engaged)
        if !pending.isEmpty {
            let left = freezer.resume(pending)
            pending = left
            pendingInfo = pendingInfo.filter { left.contains($0.key) }
        }
        // Catch-up: freeze newly started processes (relaunch, helpers) of frozen/closed apps.
        for id in engaged {
            let ms = AppCatalog.matchers(for: id, in: config)
            guard !ms.isEmpty else { continue }
            let got = freezer.freezeNewlyStarted(matching: ms)
            if !got.isEmpty { attribute(got, defaultApp: id) }
        }
    }

    /// A pid waiting for resume that belongs to an app which is frozen again (it matches the app,
    /// or descends from one of its processes) is handed back to that app instead of being resumed.
    private func reclaimPending(_ engaged: [String]) {
        let frozenIDs = engaged.filter { apps[$0]?.phase == .frozen }
        guard !pendingInfo.isEmpty, !frozenIDs.isEmpty else { return }
        let matchers = Dictionary(uniqueKeysWithValues: frozenIDs.map { ($0, AppCatalog.matchers(for: $0, in: config)) })
        for p in pendingInfo.values.sorted(by: { ($0.startTime, $0.pid) < ($1.startTime, $1.pid) }) {
            let owner = frozenIDs.first { id in
                matchers[id]!.contains { $0.matches(p) } || apps[id]!.procs[p.ppid] != nil
            }
            guard let id = owner else { continue }
            apps[id]?.procs[p.pid] = p
            pending.remove(p.pid); pendingInfo[p.pid] = nil
        }
    }

    /// Assigns newly stopped processes to the frozen app owning their parent, else to `defaultApp`
    /// (over-freezing a stray child is the safe side). A closed app that gets processes again
    /// (relaunch) is frozen anew with a fresh countdown.
    private func attribute(_ got: [ProcInfo], defaultApp: String) {
        let now = clock.now
        var touched: [String] = []
        for p in got.sorted(by: { ($0.startTime, $0.pid) < ($1.startTime, $1.pid) }) {
            let owner = ids().first { apps[$0]?.phase == .frozen && apps[$0]?.procs[p.ppid] != nil } ?? defaultApp
            if apps[owner]?.phase == .closed {
                var a = apps[owner]!
                let off = lastObservation.map { !$0.online } ?? false
                startFreeze(&a, owner, off ? .offline : a.reason,
                            deadline: off ? nil : now.addingTimeInterval(grace(owner)), now)
                apps[owner] = a
            }
            apps[owner, default: AppStatus()].procs[p.pid] = p
            if !touched.contains(owner) { touched.append(owner) }
        }
        for id in touched where apps[id]?.loggedFrozen == false {
            apps[id]?.loggedFrozen = true
            record(.frozen, id, "\(apps[id]!.reason)")
        }
    }

    private func handleTimeouts() {
        let now = clock.now
        for id in ids() {
            guard let a = apps[id], a.phase == .frozen, let d = a.deadline, d <= now else { continue }
            switch config.onTimeout {
            case .close:
                closeApp(id, now, "timeout")
            case .keepFrozen:
                apps[id]?.deadline = nil; apps[id]?.timedOut = true
            case .resume:
                if a.loggedFrozen { record(.paused, id, "timeoutResume") }
                release(id)
                var r = AppStatus(); r.phase = .released
                apps[id] = r
            }
        }
        reconcileProcesses()
    }

    private func closeApp(_ id: String, _ now: Date, _ detail: String) {
        guard var a = apps[id] else { return }
        let procs = a.procs.values.sorted { $0.pid < $1.pid }
        a.phase = .closed; a.closedAt = now; a.deadline = nil; a.timedOut = false
        a.procs = [:]; a.loggedFrozen = false
        apps[id] = a
        guard !procs.isEmpty else { return }
        record(.closed, id, detail)
        let run = _runClose, gentle = config.closeTimeout
        effects.append { run(procs, gentle) }
    }

    private func pauseFired(_ gen: Int) {
        guard gen == pauseGen, pausedUntil != nil else { return }
        endPause()
    }

    private func endPause() {
        pausedUntil = nil
        pauseTimer?.cancel(); pauseTimer = nil
        pauseGen += 1
        record(.paused, nil, "resumeProtection")
        requestCheck()
        if let o = lastObservation { process(o) } else { reconcileProcesses() }
    }

    private func deadlineFired(_ gen: Int) {
        guard gen == timerGen, !sleeping, pausedUntil == nil else { return }
        handleTimeouts()
    }

    /// One timer for the earliest deadline; re-armed after every change. Never armed while
    /// asleep or paused, and there is no deadline at all while offline.
    private func rearmDeadlineTimer() {
        deadlineTimer?.cancel(); deadlineTimer = nil
        timerGen += 1
        guard !sleeping, pausedUntil == nil,
              let next = apps.values.filter({ $0.phase == .frozen }).compactMap({ $0.deadline }).min() else { return }
        let gen = timerGen
        deadlineTimer = clock.schedule(after: next.timeIntervalSince(clock.now)) { [weak self] in
            self?.perform { self?.deadlineFired(gen) }
        }
    }

    // MARK: Helpers (lock held)

    private func ids() -> [String] { AppCatalog.appIDs(in: config) }
    private func grace(_ id: String) -> TimeInterval { config.appGrace[id] ?? config.grace }
    private func frozenSet() -> Set<String> { Set(apps.filter { $0.value.phase == .frozen }.keys) }

    private func computeState() -> GuardState {
        if let u = pausedUntil { return .paused(until: u) }
        let order = ids() + apps.keys.filter { !ids().contains($0) }.sorted()
        let fr = order.compactMap { apps[$0] }.filter { $0.phase == .frozen }
        if let first = fr.min(by: { $0.since < $1.since }) {
            let timed = fr.filter { $0.deadline != nil }
            let lead = timed.min(by: { $0.deadline! < $1.deadline! }) ?? first
            return .frozen(since: first.since, reason: lead.reason, deadline: lead.deadline)
        }
        if let c = apps.values.filter({ $0.phase == .closed }).compactMap({ $0.closedAt }).max() { return .closed(c) }
        return .ok
    }

    private func record(_ k: EventKind, _ app: String?, _ detail: String) {
        log.append(Event(date: clock.now, kind: k, app: app, detail: detail))
    }

    private func requestCheck() {
        let cb = _onCheckRequested
        effects.append { cb?() }
    }

    /// Logs a `leak` event on the rising edge of each leak signal (only while online).
    private func logLeakEdges(_ o: Observation) {
        var now: Set<String> = []
        if o.online {
            if o.ipv6Leak { now.insert("\(Reason.ipv6Leak)") }
            if o.routeLeak { now.insert("\(Reason.routeLeak)") }
            if o.dnsLeak && config.dnsCheck != .off { now.insert("\(Reason.dnsLeak)") }
        }
        for r in now.subtracting(lastLeaks).sorted() { record(.leak, nil, r) }
        lastLeaks = now
    }

    /// The single IP confirmed by >= minAgree answers (same rule as `evaluate`), else nil.
    static func confirmedIP(_ o: Observation, minAgree: Int) -> String? {
        guard o.online else { return nil }
        var groups: [String: (ip: String, n: Int)] = [:]
        for a in o.ips { groups[a.ip + "|" + a.country.uppercased(), default: (a.ip, 0)].n += 1 }
        let ok = groups.values.filter { $0.n >= max(1, minAgree) }
        return ok.count == 1 ? ok[0].ip : nil
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    /// Runs `body` under the lock, re-arms the countdown, publishes state changes, then runs the
    /// collected effects outside the lock (or enqueues them, in order, on `callbackQueue`).
    private func perform(_ body: () -> Void) {
        lock.lock()
        body()
        rearmDeadlineTimer()
        let s = computeState(), f = frozenSet()
        if s != publishedState || f != publishedFrozen {
            publishedState = s; publishedFrozen = f
            let cb = _onChange
            effects.append { cb?(s) }
        }
        let fx = effects
        effects = []
        if let q = _callbackQueue, !fx.isEmpty {
            q.async { fx.forEach { $0() } }
            lock.unlock()
        } else {
            lock.unlock()
            fx.forEach { $0() }
        }
    }
}
