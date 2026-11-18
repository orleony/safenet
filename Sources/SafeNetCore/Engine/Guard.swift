import Foundation

/// Aggregate protection state shown in the UI.
///
/// Aggregation rule (precedence top to bottom):
///  1. `.paused(until:)`  the user paused protection (all apps resumed, nothing is frozen);
///  2. `.frozen(...)`     at least one app is in the frozen phase (stopped, or should be stopped
///                        but freezing failed). `since` = earliest freeze start among them;
///                        `deadline` = earliest close deadline (nil when none has a countdown:
///                        offline, or `keep_frozen` after the timeout); `reason` = `.freezeFailed`
///                        when ANY of them could not be stopped (it is running unrestricted), else
///                        the reason of the app owning the earliest deadline (else of the earliest
///                        frozen app, ties broken by config order);
///  3. `.closed(date)`    no app is frozen, and at least one app was closed (timeout or "close now")
///                        and has not had a passing check since; date = latest close;
///  4. `.ok`              everything else, including apps released by `on_timeout: resume`
///                        (see `releasedApps`).
/// `deadline` is a display value (wall clock = now + remaining monotonic time, rounded to whole seconds).
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
///  - countdowns run on `Clock.uptime` (monotonic, paused during sleep), so wall-clock jumps can
///    neither shorten nor lengthen them; sleep: countdowns are cancelled in `willSleep`, `didWake`
///    restarts them from full grace and requests a fresh check;
///  - an app whose processes cannot be stopped (freeze failed) is reported (`freezeFailedApps`,
///    reason `.freezeFailed`, a `leak` event "freezeFailed") and still closed at the deadline:
///    closing targets the app's currently running processes, not only the ones stopped earlier.
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
        /// Close deadline on the monotonic `Clock.uptime` base.
        var deadline: TimeInterval?
        /// `keep_frozen` timeout reached: stays frozen without a new countdown until a pass.
        var timedOut = false
        /// Frozen only as a precaution by `networkChanged()` while the network was offline.
        var precautionary = false
        var closedAt: Date?
        /// Processes stopped on behalf of this app (roots and descendants).
        var procs: [Int32: ProcInfo] = [:]
        /// Should be frozen, but matching processes are running unstopped.
        var freezeFailed = false
        /// Only protected (system) processes match and they run: the app cannot be protected at
        /// all (implies `freezeFailed`; never closed, never reported as frozen).
        var systemOnly = false
        /// Frozen phase, but nothing of the app runs (UI: «не запущено»).
        var notRunning = false
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
    /// Processes handed to `runClose` (pid -> start time): not "running unstopped" while they die.
    private var closing: [Int32: Date] = [:]
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
    private var publishedFailed: Set<String> = []
    private var publishedNotRunning: Set<String> = []
    private var effects: [() -> Void] = []

    private var _onChange: ((GuardState) -> Void)?
    private var _onAllowIP: ((String) -> Void)?
    private var _onCheckRequested: (() -> Void)?
    private var _callbackQueue: DispatchQueue?
    private var _runClose: ([ProcInfo], TimeInterval) -> Void

    /// Fired after every change of `state`, `frozenApps` or `freezeFailedApps`.
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
    /// Apps currently frozen (decided per app) whose processes are actually stopped.
    public var frozenApps: Set<String> { locked { frozenSet() } }
    /// Apps that should be frozen but whose running processes could not be stopped.
    public var freezeFailedApps: Set<String> { locked { failedSet() } }
    /// Apps whose only running processes are protected system processes (e.g. a rule matching
    /// /System/Applications/Notes.app): they run unrestricted and are never reported frozen.
    /// Always a subset of `freezeFailedApps`.
    public var unprotectableApps: Set<String> {
        locked { Set(apps.filter { $0.value.phase == .frozen && $0.value.systemOnly }.keys) }
    }
    /// Apps in the frozen phase with no running process at all (nothing to freeze).
    public var notRunningApps: Set<String> { locked { notRunningSet() } }
    /// Apps released by `on_timeout: resume`; protected again after the next passing check.
    /// Apps closed (timeout or "close now") that have not passed a check since.
    public var closedApps: Set<String> { locked { Set(apps.filter { $0.value.phase == .closed }.keys) } }

    public var releasedApps: Set<String> { locked { Set(apps.filter { $0.value.phase == .released }.keys) } }
    /// Pids still stopped although a resume was requested (retried on every tick).
    public var unresolvedPIDs: Set<Int32> { locked { pending } }

    // MARK: Entry points

    /// One network check result. Also a "tick": retries unresolved resumes and freezes newly
    /// started processes of frozen apps.
    public func apply(_ o: Observation) { perform { process(o) } }

    /// Maintenance without a new observation (retries, catch-up freezing).
    public func tick() { perform { reconcileProcesses() } }

    /// Pids still stopped from an earlier run (start-up reconcile could not resume them): retried
    /// on every tick like any unresolved resume, also while other apps are frozen.
    public func adoptUnresolved(_ pids: Set<Int32>) {
        guard !pids.isEmpty else { return }
        perform { pending.formUnion(pids); reconcileProcesses() }
    }

    /// User pause: protection off, all apps resumed, protection returns after `d` (max 24 h).
    public func pause(for d: TimeInterval) {
        guard d.isFinite, d > 0 else { return }
        perform {
            let len = min(d, 86_400)
            pausedUntil = clock.now.addingTimeInterval(len)
            for id in Array(apps.keys) { release(id) }
            apps = [:]
            record(.paused, nil, "pause")
            schedulePauseTimer(after: len)
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
                if let d = apps[id]?.deadline { apps[id]?.deadline = d + by }
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
    /// pending a fresh check. With the last observation offline the freeze is precautionary: no
    /// countdown (nothing closes offline), and with `block_when_offline` off an offline check
    /// result releases it again. Ignored (only logged) while paused.
    public func networkChanged() {
        perform {
            record(.networkChanged, nil, "networkChanged")
            requestCheck()
            guard pausedUntil == nil else { return }
            let off = lastObservation.map { !$0.online } ?? false
            for id in ids() {
                let p = apps[id]?.phase ?? .ok
                guard p == .ok || p == .released else { continue }
                var a = AppStatus()
                if off {
                    startFreeze(&a, .offline, deadline: nil)
                    a.precautionary = true
                } else if emptyAllow(id) {
                    startFreeze(&a, .noAllowList, deadline: nil)   // first run: never closed
                } else {
                    startFreeze(&a, .networkChanged, deadline: clock.uptime + grace(id))
                }
                apps[id] = a
            }
            reconcileProcesses()
        }
    }

    public func willSleep() { perform { sleeping = true } }

    public func didWake() {
        perform {
            sleeping = false
            // The pause end is a wall-clock time the user sees ("Пауза до HH:MM"), but its timer
            // runs on uptime, which stops during sleep: re-arm it for the remaining wall time.
            if let u = pausedUntil {
                let left = u.timeIntervalSince(clock.now)
                if left <= 0 { endPause() } else { schedulePauseTimer(after: left) }
            }
            let up = clock.uptime
            for id in ids() where apps[id]?.phase == .frozen && apps[id]?.deadline != nil && !emptyAllow(id) {
                apps[id]?.deadline = up + grace(id)
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
        for id in ids() {
            let v = evaluate(o, allow: effectiveAllow(for: id, in: config), minAgree: config.minAgree,
                             dnsCheck: config.dnsCheck)
            transition(id, v)
        }
        reconcileProcesses()
    }

    private func transition(_ id: String, _ v: Verdict) {
        var a = apps[id] ?? AppStatus()
        switch (v, a.phase) {
        case (.ok, .frozen):
            if a.loggedFrozen { record(.resumed, id, "checkPassed") }
            release(id)
            apps[id] = nil
            return
        case (.ok, _):
            a = AppStatus()
        case (.offline, .ok):
            if config.blockWhenOffline { startFreeze(&a, .offline, deadline: nil) }
        case (.offline, .frozen):
            if a.precautionary && !config.blockWhenOffline {
                release(id)                                // offline confirmed, user lets apps run
                apps[id] = nil
                return
            }
            a.reason = .offline; a.deadline = nil          // countdown suspended, never closes offline
        case (.freeze(.noAllowList), .ok):
            startFreeze(&a, .noAllowList, deadline: nil)   // like offline: frozen, never closed
        case (.freeze(.noAllowList), .frozen):
            a.reason = .noAllowList; a.deadline = nil
            a.precautionary = false
        case (.freeze(let r), .ok):
            startFreeze(&a, r, deadline: clock.uptime + grace(id))
        case (.freeze(let r), .frozen):
            if a.deadline == nil && !a.timedOut { a.deadline = clock.uptime + grace(id) }
            a.reason = r
            a.precautionary = false
        case (.offline, _), (.freeze, _):
            break                                          // closed / released: wait for a pass
        }
        apps[id] = a
    }

    private func startFreeze(_ a: inout AppStatus, _ r: Reason, deadline: TimeInterval?) {
        let procs = a.procs
        a = AppStatus()
        a.phase = .frozen; a.since = clock.now; a.reason = r; a.deadline = deadline; a.procs = procs
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
        // Catch-up: freeze newly started processes (relaunch, helpers) of frozen/closed apps,
        // then check that nothing of them is left running unstopped.
        for id in engaged {
            let ms = AppCatalog.matchers(for: id, in: config)
            guard !ms.isEmpty else { continue }
            let got = freezer.freezeNewlyStarted(matching: ms)
            if !got.isEmpty { attribute(got, defaultApp: id) }
            let stopped = freezer.frozenPIDs
            let live = freezer.matchingProcesses(ms)
            let loose = live.filter { p in
                !stopped.contains(p.pid) && closing[p.pid].map { !Freezer.same(p.startTime, $0) } ?? true
            }
            let mine = apps[id]?.procs.isEmpty ?? true
            let sys = live.isEmpty && mine ? !freezer.protectedMatchingProcesses(ms).isEmpty : false
            apps[id]?.notRunning = live.isEmpty && mine && !sys
            updateFreezeFailed(id, running: !loose.isEmpty || sys, systemOnly: sys)
        }
        pruneClosing()
    }

    /// Forgets closing entries whose process is gone (or whose pid now belongs to another process).
    private func pruneClosing() {
        guard !closing.isEmpty else { return }
        var ms: [AppMatcher] = []
        for id in ids() { ms += AppCatalog.matchers(for: id, in: config) }
        let alive = Dictionary(freezer.matchingProcesses(ms).map { ($0.pid, $0.startTime) }, uniquingKeysWith: { a, _ in a })
        closing = closing.filter { pid, start in alive[pid].map { Freezer.same($0, start) } ?? false }
    }

    private func updateFreezeFailed(_ id: String, running: Bool, systemOnly: Bool) {
        guard var a = apps[id] else { return }
        if running {
            if a.phase == .closed { reopen(&a, id) }           // relaunched but cannot be stopped
            if !a.freezeFailed || a.systemOnly != systemOnly {
                record(.leak, id, systemOnly ? "unprotectable" : "freezeFailed")
            }
            a.freezeFailed = true
            a.systemOnly = systemOnly
            a.notRunning = false
        } else {
            a.freezeFailed = false
            a.systemOnly = false
        }
        apps[id] = a
    }

    /// A closed app with processes again (relaunch): frozen anew with a fresh countdown
    /// (none while offline).
    private func reopen(_ a: inout AppStatus, _ id: String) {
        let off = lastObservation.map { !$0.online } ?? false
        let none = emptyAllow(id)
        startFreeze(&a, off ? .offline : none ? .noAllowList : a.reason,
                    deadline: off || none ? nil : clock.uptime + grace(id))
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
        var touched: [String] = []
        for p in got.sorted(by: { ($0.startTime, $0.pid) < ($1.startTime, $1.pid) }) {
            let owner = ids().first { apps[$0]?.phase == .frozen && apps[$0]?.procs[p.ppid] != nil } ?? defaultApp
            if apps[owner]?.phase == .closed {
                var a = apps[owner]!
                reopen(&a, owner)
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
        let now = clock.now, up = clock.uptime
        for id in ids() {
            guard let a = apps[id], a.phase == .frozen, let d = a.deadline, d <= up else { continue }
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

    /// Closes the processes stopped for this app plus whatever of it is running right now (a
    /// failed freeze must not leave it running). `Freezer.close` re-checks identity and the
    /// never-freeze list.
    private func closeApp(_ id: String, _ now: Date, _ detail: String) {
        guard var a = apps[id] else { return }
        if a.systemOnly {
            // Only protected processes: nothing may be closed. Stays reported, no new countdown.
            a.deadline = nil; a.timedOut = true
            apps[id] = a
            return
        }
        var targets = a.procs
        for p in freezer.matchingProcesses(AppCatalog.matchers(for: id, in: config)) where targets[p.pid] == nil {
            targets[p.pid] = p
        }
        let procs = targets.values.sorted { $0.pid < $1.pid }
        a.phase = .closed; a.closedAt = now; a.deadline = nil; a.timedOut = false
        a.procs = [:]; a.loggedFrozen = false; a.freezeFailed = false; a.precautionary = false
        apps[id] = a
        guard !procs.isEmpty else { return }
        record(.closed, id, detail)
        for p in procs { closing[p.pid] = p.startTime }
        let run = _runClose, gentle = config.closeTimeout
        effects.append { run(procs, gentle) }
    }

    private func schedulePauseTimer(after len: TimeInterval) {
        pauseTimer?.cancel()
        pauseGen += 1
        let gen = pauseGen
        pauseTimer = clock.schedule(after: len) { [weak self] in
            self?.perform { self?.pauseFired(gen) }
        }
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
        deadlineTimer = clock.schedule(after: next - clock.uptime) { [weak self] in
            self?.perform { self?.deadlineFired(gen) }
        }
    }

    // MARK: Helpers (lock held)

    private func ids() -> [String] { AppCatalog.appIDs(in: config) }
    private func grace(_ id: String) -> TimeInterval { config.appGrace[id] ?? config.grace }
    private func emptyAllow(_ id: String) -> Bool {
        let a = effectiveAllow(for: id, in: config)
        return a.ips.isEmpty && a.countries.isEmpty
    }
    private func frozenSet() -> Set<String> {
        Set(apps.filter { $0.value.phase == .frozen && !$0.value.freezeFailed }.keys)
    }
    private func failedSet() -> Set<String> {
        Set(apps.filter { $0.value.phase == .frozen && $0.value.freezeFailed }.keys)
    }
    private func notRunningSet() -> Set<String> {
        Set(apps.filter { $0.value.phase == .frozen && $0.value.notRunning && !$0.value.freezeFailed }.keys)
    }

    private func computeState() -> GuardState {
        if let u = pausedUntil { return .paused(until: u) }
        let all = ids()
        let order = all + apps.keys.filter { !all.contains($0) }.sorted()
        let fr = order.compactMap { apps[$0] }.filter { $0.phase == .frozen }
        if let first = fr.min(by: { $0.since < $1.since }) {
            let timed = fr.filter { $0.deadline != nil }
            let lead = timed.min(by: { $0.deadline! < $1.deadline! }) ?? first
            let reason: Reason = fr.contains { $0.freezeFailed } ? .freezeFailed : lead.reason
            // Rounded to whole seconds: `now` and `uptime` are read separately, so the raw value
            // jitters by microseconds and would publish a "change" on every tick.
            let shown = lead.deadline.map {
                Date(timeIntervalSince1970: clock.now.addingTimeInterval($0 - clock.uptime).timeIntervalSince1970.rounded())
            }
            return .frozen(since: first.since, reason: reason, deadline: shown)
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
        let s = computeState(), f = frozenSet(), x = failedSet(), n = notRunningSet()
        if s != publishedState || f != publishedFrozen || x != publishedFailed || n != publishedNotRunning {
            publishedState = s; publishedFrozen = f; publishedFailed = x; publishedNotRunning = n
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
