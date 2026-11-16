import Foundation
import Darwin
@testable import SafeNetCore

// Guard tests run on FakeClock with a fake ProcessTable and a fake Signaler:
// fully deterministic (no sleeps) and never signal a real process.

private let me = getuid()
private let fakeSelf: Int32 = 7

private func gproc(_ pid: Int32, _ app: String, ppid: Int32 = 1, start: Double = 1000) -> ProcInfo {
    let path = "/Applications/\(app).app/Contents/MacOS/\(app)"
    return ProcInfo(pid: pid, ppid: ppid, name: app, path: path, args: path,
                    startTime: Date(timeIntervalSince1970: start), uid: me)
}

private final class GTable: ProcessTable {
    private let lock = NSLock()
    private var _procs: [ProcInfo]
    var failing = false
    init(_ p: [ProcInfo]) { _procs = p }
    var procs: [ProcInfo] {
        get { lock.lock(); defer { lock.unlock() }; return _procs }
        set { lock.lock(); _procs = newValue; lock.unlock() }
    }
    func list() -> [ProcInfo] { failing ? [] : procs }
    func snapshot() -> [ProcInfo]? { failing ? nil : procs }
    func remove(_ pid: Int32) { procs = procs.filter { $0.pid != pid } }
}

private final class GSignaler: Signaler {
    private let lock = NSLock()
    private var _sent: [(sig: Int32, pid: Int32)] = []
    var failFor: Set<Int32> = []
    var onSend: ((Int32, Int32) -> Void)?
    var sent: [(sig: Int32, pid: Int32)] { lock.lock(); defer { lock.unlock() }; return _sent }
    func send(_ sig: Int32, to pid: Int32) -> Bool {
        lock.lock(); _sent.append((sig, pid)); lock.unlock()
        onSend?(sig, pid)
        return !failFor.contains(pid)
    }
    func pids(_ sig: Int32) -> [Int32] { sent.filter { $0.sig == sig }.map { $0.pid } }
    func count(_ sig: Int32, _ pid: Int32) -> Int { sent.filter { $0.sig == sig && $0.pid == pid }.count }
}

private func ans(_ ip: String, _ cc: String) -> IPAnswer { IPAnswer(ip: ip, country: cc) }
private func obs(_ ips: [IPAnswer], online: Bool = true, ipv6: Bool = false, dns: Bool = false,
                 route: Bool = false) -> Observation {
    Observation(online: online, ips: ips, ipv6Leak: ipv6, dnsLeak: dns, routeLeak: route, trustedNetwork: false)
}
private let good = obs([ans("1.2.3.4", "NL"), ans("1.2.3.4", "NL")])
private let bad = obs([ans("5.6.7.8", "DE"), ans("5.6.7.8", "DE")])
private let disagree = obs([ans("1.1.1.1", "NL"), ans("2.2.2.2", "NL"), ans("3.3.3.3", "FR")])
private let offline = obs([], online: false)

private func baseConfig() -> Config {
    var c = Config.default
    c.apps = ["claude", "telegram"]
    c.allow = AllowList(countries: ["NL"])
    c.grace = 20
    c.closeTimeout = 0
    return c
}

private func awaitAsync(_ op: @escaping () async -> Void) {
    let sem = DispatchSemaphore(value: 0)
    Task { await op(); sem.signal() }
    sem.wait()
}

/// Test fixture: Claude (100) and Telegram (200) running.
private final class Rig {
    let table: GTable
    let sig = GSignaler()
    let clock = FakeClock(start: Date(timeIntervalSince1970: 1_800_000_000))
    let dir: URL
    let freezer: Freezer
    let log: EventLog
    let guardian: Guard
    var states: [GuardState] = []
    var checks = 0
    var allowed: [String] = []
    var closedBatches: [[Int32]] = []

    init(_ config: Config = baseConfig(), procs: [ProcInfo] = [gproc(100, "Claude"), gproc(200, "Telegram")],
         unwritableJournal: Bool = false) {
        table = GTable(procs)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("safenet-guard-\(UUID().uuidString)")
        var journal = dir.appendingPathComponent("frozen.json")
        if unwritableJournal {
            // The journal's "directory" is a regular file: createDirectory fails -> no SIGSTOP.
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let blocker = dir.appendingPathComponent("blocker")
            FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
            journal = blocker.appendingPathComponent("frozen.json")
        }
        freezer = Freezer(table: table, signaler: sig, journal: journal,
                          selfPID: fakeSelf, myUID: me, pollInterval: 0.01)
        log = EventLog(url: dir.appendingPathComponent("events.jsonl"))
        guardian = Guard(config: config, freezer: freezer, clock: clock, log: log)
        let t = table, f = freezer
        sig.onSend = { s, pid in if s == SIGTERM { t.remove(pid) } }   // apps quit on SIGTERM
        guardian.runClose = { [weak self] procs, gentle in
            self?.closedBatches.append(procs.map { $0.pid }.sorted())
            awaitAsync { await f.close(procs, gentle: gentle) }
        }
        guardian.onChange = { [weak self] s in self?.states.append(s) }
        guardian.onCheckRequested = { [weak self] in self?.checks += 1 }
        guardian.onAllowIP = { [weak self] ip in self?.allowed.append(ip) }
    }
    deinit { try? FileManager.default.removeItem(at: dir) }

    var now: Date { clock.now }
    func kinds() -> [EventKind] { log.recent(limit: 1000).reversed().map { $0.kind } }
    func events(_ k: EventKind) -> [Event] { log.recent(limit: 1000, kinds: [k]).reversed() }
}

private func isFrozen(_ s: GuardState) -> Bool { if case .frozen = s { return true }; return false }
private func deadline(_ s: GuardState) -> Date?? {
    if case .frozen(_, _, let d) = s { return .some(d) }
    return nil
}
private func reason(_ s: GuardState) -> Reason? {
    if case .frozen(_, let r, _) = s { return r }
    return nil
}

func registerGuardTests() {
    test("testFreezeThenOkResumesApps") {
        let r = Rig(); let g = r.guardian
        g.apply(bad)
        expect(isFrozen(g.state), "\(g.state)")
        expectEqual(reason(g.state), .countryNotAllowed)
        expectEqual(g.frozenApps, ["claude", "telegram"])
        expectEqual(Set(r.sig.pids(SIGSTOP)), [100, 200])
        expectEqual(r.freezer.frozenPIDs, [100, 200])
        g.apply(good)
        expectEqual(g.state, .ok)
        expectEqual(g.frozenApps, [])
        expectEqual(Set(r.sig.pids(SIGCONT)), [100, 200])
        expectEqual(r.freezer.frozenPIDs, [])
        expectEqual(r.kinds(), [.frozen, .frozen, .resumed, .resumed])
        expectEqual(Set(r.events(.resumed).compactMap { $0.app }), ["claude", "telegram"])
    }

    test("testCloseAfterGrace") {
        let r = Rig(); let g = r.guardian
        g.apply(bad)
        expectEqual(deadline(g.state), .some(r.now.addingTimeInterval(20)))
        r.clock.advance(by: 19.9)
        expect(isFrozen(g.state))
        expectEqual(r.sig.pids(SIGTERM), [])
        r.clock.advance(by: 0.2)
        if case .closed = g.state {} else { expect(false, "expected closed, got \(g.state)") }
        expectEqual(Set(r.sig.pids(SIGTERM)), [100, 200])
        expectEqual(g.frozenApps, [])
        expectEqual(r.events(.closed).count, 2)
        expectEqual(r.freezer.frozenPIDs, [])
    }

    test("testKeepFrozenWhenConfigured") {
        var c = baseConfig(); c.onTimeout = .keepFrozen
        let r = Rig(c); let g = r.guardian
        g.apply(bad)
        r.clock.advance(by: 100)
        expect(isFrozen(g.state))
        expectEqual(deadline(g.state), .some(nil))
        expectEqual(r.sig.pids(SIGTERM), [])
        expectEqual(r.sig.pids(SIGCONT), [])
        expectEqual(g.frozenApps, ["claude", "telegram"])
        g.apply(bad)   // stays frozen, no new countdown
        expectEqual(deadline(g.state), .some(nil))
        g.apply(good)
        expectEqual(g.state, .ok)
        expectEqual(Set(r.sig.pids(SIGCONT)), [100, 200])
    }

    test("testResumeWhenConfigured") {
        var c = baseConfig(); c.onTimeout = .resume
        let r = Rig(c); let g = r.guardian
        g.apply(bad)
        r.clock.advance(by: 21)
        expectEqual(g.state, .ok)
        expectEqual(g.frozenApps, [])
        expectEqual(g.releasedApps, ["claude", "telegram"])
        expectEqual(Set(r.sig.pids(SIGCONT)), [100, 200])
        expectEqual(r.sig.pids(SIGTERM), [])
        g.apply(bad)   // released: not refrozen while the check keeps failing
        expectEqual(r.sig.pids(SIGSTOP).count, 2)
        g.apply(good)
        expectEqual(g.releasedApps, [])
        g.apply(bad)   // after a pass the protection is back
        expectEqual(r.sig.pids(SIGSTOP).count, 4)
        expect(isFrozen(g.state))
    }

    test("testOfflineFreezesButNeverCloses") {
        let r = Rig(); let g = r.guardian
        g.apply(offline)
        expect(isFrozen(g.state))
        expectEqual(reason(g.state), .offline)
        expectEqual(deadline(g.state), .some(nil))
        for _ in 0..<10 { r.clock.advance(by: 20); g.apply(offline) }
        expect(isFrozen(g.state), "\(g.state)")
        expectEqual(r.sig.pids(SIGTERM), [])
        expectEqual(r.clock.pendingCount, 0, "no close scheduled while offline")
        // A running countdown is suspended when the network disappears.
        g.apply(bad)
        expectEqual(deadline(g.state), .some(r.now.addingTimeInterval(20)))
        r.clock.advance(by: 10)
        g.apply(offline)
        expectEqual(deadline(g.state), .some(nil))
        r.clock.advance(by: 200)
        expectEqual(r.sig.pids(SIGTERM), [])
        // Back online and still wrong: a fresh full countdown.
        g.apply(bad)
        expectEqual(deadline(g.state), .some(r.now.addingTimeInterval(20)))
    }

    test("testOfflineWithoutBlockDoesNotFreezeNewApps") {
        var c = baseConfig(); c.blockWhenOffline = false
        let r = Rig(c); let g = r.guardian
        g.apply(offline)
        expectEqual(g.state, .ok)
        expectEqual(r.sig.pids(SIGSTOP), [])
        g.apply(bad)
        g.apply(offline)   // already frozen apps stay frozen, countdown suspended
        expect(isFrozen(g.state))
        expectEqual(deadline(g.state), .some(nil))
        r.clock.advance(by: 100)
        expectEqual(r.sig.pids(SIGTERM), [])
    }

    test("testPerAppGraceOverridesGlobal") {
        var c = baseConfig(); c.appGrace = ["telegram": 5]
        let r = Rig(c); let g = r.guardian
        g.apply(bad)
        expectEqual(deadline(g.state), .some(r.now.addingTimeInterval(5)), "aggregate deadline = earliest")
        r.clock.advance(by: 6)
        expectEqual(r.sig.pids(SIGTERM), [200])
        expectEqual(g.frozenApps, ["claude"])
        expect(isFrozen(g.state))
        expectEqual(deadline(g.state), .some(r.now.addingTimeInterval(14)))
        r.clock.advance(by: 15)
        expectEqual(Set(r.sig.pids(SIGTERM)), [100, 200])
    }

    test("testOkResetsDeadline") {
        let r = Rig(); let g = r.guardian
        g.apply(bad)
        r.clock.advance(by: 15)
        g.apply(good)
        r.clock.advance(by: 1)
        g.apply(bad)
        expectEqual(deadline(g.state), .some(r.now.addingTimeInterval(20)))
        r.clock.advance(by: 19)
        expectEqual(r.sig.pids(SIGTERM), [], "old deadline must not fire")
        r.clock.advance(by: 2)
        expectEqual(Set(r.sig.pids(SIGTERM)), [100, 200])
    }

    test("testPauseUnfreezesAndReturnsAfterTimer") {
        let r = Rig(); let g = r.guardian
        g.apply(bad)
        g.pause(for: 900)
        expectEqual(g.state, .paused(until: r.now.addingTimeInterval(900)))
        expectEqual(Set(r.sig.pids(SIGCONT)), [100, 200])
        expectEqual(r.freezer.frozenPIDs, [])
        expectEqual(g.frozenApps, [])
        g.apply(bad)   // protection is off during the pause
        expectEqual(r.sig.pids(SIGSTOP).count, 2)
        r.clock.advance(by: 100)
        expectEqual(r.sig.pids(SIGTERM), [], "no close during pause")
        g.apply(good)
        r.clock.advance(by: 800)
        expectEqual(g.state, .ok, "pause over, last check was good")
        expect(r.checks >= 1, "fresh check requested when protection returns")
        expectEqual(r.events(.paused).count, 2)   // start + end
    }

    test("testPauseExpiryRefreezesImmediatelyWhenBad") {
        let r = Rig(); let g = r.guardian
        g.pause(for: 60)
        g.apply(bad)
        expectEqual(r.sig.pids(SIGSTOP), [])
        r.clock.advance(by: 60)
        expect(isFrozen(g.state), "\(g.state)")
        expectEqual(Set(r.sig.pids(SIGSTOP)), [100, 200])
        expectEqual(deadline(g.state), .some(r.now.addingTimeInterval(20)))
    }

    test("testResumeEndsPauseEarly") {
        let r = Rig(); let g = r.guardian
        g.pause(for: 900)
        g.apply(bad)
        g.resume()
        expect(isFrozen(g.state))
        expectEqual(Set(r.sig.pids(SIGSTOP)), [100, 200])
        r.clock.advance(by: 900)   // stale pause timer does nothing harmful
        if case .closed = g.state {} else { expect(false, "\(g.state)") }
    }

    test("testSleepDoesNotConsumeGrace") {
        let r = Rig(); let g = r.guardian
        g.apply(bad)
        r.clock.advance(by: 10)
        g.willSleep()
        r.clock.advance(by: 3600)
        expectEqual(r.sig.pids(SIGTERM), [], "grace must not run out during sleep")
        let before = r.checks
        g.didWake()
        expect(isFrozen(g.state))
        expectEqual(deadline(g.state), .some(r.now.addingTimeInterval(20)), "fresh countdown after wake")
        expectEqual(r.checks, before + 1, "fresh check after wake")
        r.clock.advance(by: 19)
        expectEqual(r.sig.pids(SIGTERM), [])
        r.clock.advance(by: 2)
        expectEqual(Set(r.sig.pids(SIGTERM)), [100, 200])
    }

    test("testDisagreeingServicesFreezeButDoNotCloseBeforeGrace") {
        let r = Rig(); let g = r.guardian
        g.apply(disagree)
        expect(isFrozen(g.state))
        expectEqual(reason(g.state), .unconfirmed)
        r.clock.advance(by: 10); g.apply(obs([]))   // nobody answered, network up
        expectEqual(reason(g.state), .unconfirmed)
        r.clock.advance(by: 9.9); g.apply(disagree)
        expectEqual(r.sig.pids(SIGTERM), [], "no close before the full grace period")
        expect(isFrozen(g.state))
        r.clock.advance(by: 0.2)
        expectEqual(Set(r.sig.pids(SIGTERM)), [100, 200])
    }

    test("testPerAppVerdictsFreezeOnlyAffectedApp") {
        var c = baseConfig(); c.appRules = ["telegram": AllowList(countries: ["DE"])]
        let r = Rig(c); let g = r.guardian
        g.apply(bad)   // DE: allowed for telegram only
        expectEqual(g.frozenApps, ["claude"])
        expectEqual(r.sig.pids(SIGSTOP), [100])
        g.apply(good)  // NL: claude ok, telegram (rules replace the common list) frozen
        expectEqual(g.frozenApps, ["telegram"])
        expectEqual(r.sig.pids(SIGCONT), [100])
        expectEqual(r.sig.pids(SIGSTOP), [100, 200])
        expectEqual(r.freezer.frozenPIDs, [200])
    }

    test("testRouteLeakFreezesWithCountdownNotPause") {
        let r = Rig(); let g = r.guardian
        g.apply(obs([ans("1.2.3.4", "NL"), ans("1.2.3.4", "NL")], route: true))
        expect(isFrozen(g.state), "\(g.state)")
        expectEqual(reason(g.state), .routeLeak)
        expectEqual(deadline(g.state), .some(r.now.addingTimeInterval(20)))
        expectEqual(r.events(.leak).map { $0.detail }, ["routeLeak"])
        r.clock.advance(by: 21)
        expectEqual(Set(r.sig.pids(SIGTERM)), [100, 200])
    }

    test("testDNSLeakInWarnModeLogsButDoesNotFreeze") {
        let r = Rig(); let g = r.guardian
        g.apply(obs([ans("1.2.3.4", "NL"), ans("1.2.3.4", "NL")], dns: true))
        expectEqual(g.state, .ok)
        g.apply(obs([ans("1.2.3.4", "NL"), ans("1.2.3.4", "NL")], dns: true))
        expectEqual(r.events(.leak).map { $0.detail }, ["dnsLeak"], "logged once per rising edge")
    }

    test("testExtendPushesDeadlines") {
        let r = Rig(); let g = r.guardian
        let t0 = r.now
        g.apply(bad)
        r.clock.advance(by: 10)
        g.extend(by: 30)
        expectEqual(deadline(g.state), .some(t0.addingTimeInterval(50)))
        r.clock.advance(by: 30)
        expectEqual(r.sig.pids(SIGTERM), [])
        r.clock.advance(by: 11)
        expectEqual(Set(r.sig.pids(SIGTERM)), [100, 200])
    }

    test("testCloseNowClosesFrozenAppsAndLogs") {
        var c = baseConfig(); c.appRules = ["telegram": AllowList(countries: ["DE"])]
        let r = Rig(c); let g = r.guardian
        g.apply(bad)
        g.closeNow()
        expectEqual(r.sig.pids(SIGTERM), [100], "only frozen apps are closed")
        if case .closed = g.state {} else { expect(false, "\(g.state)") }
        expectEqual(r.events(.closed).map { $0.app }, ["claude"])
        expectEqual(r.events(.closed).map { $0.detail }, ["closeNow"])
        expectEqual(r.closedBatches, [[100]])
        r.clock.advance(by: 100)   // the old deadline is gone
        expectEqual(r.sig.pids(SIGTERM), [100])
    }

    test("testUnresolvedResumeRetriedUntilEmpty") {
        let r = Rig(); let g = r.guardian
        g.apply(bad)
        r.table.failing = true   // listing unknown -> Freezer keeps the entries
        g.apply(good)
        expectEqual(g.state, .ok)
        expectEqual(g.unresolvedPIDs, [100, 200])
        expectEqual(r.freezer.frozenPIDs, [100, 200])
        g.tick()
        expectEqual(g.unresolvedPIDs, [100, 200])
        r.table.failing = false
        g.tick()
        expectEqual(g.unresolvedPIDs, [])
        expectEqual(r.freezer.frozenPIDs, [])
        expectEqual(Set(r.sig.pids(SIGCONT)), [100, 200])
    }

    test("testNoFreezeNewlyStartedAfterUnlockRequested") {
        let r = Rig(); let g = r.guardian
        g.apply(bad)
        r.sig.failFor = [100]          // SIGCONT to 100 fails -> stays journaled
        g.apply(good)
        expectEqual(g.unresolvedPIDs, [100])
        r.table.procs = r.table.procs + [gproc(101, "Claude", ppid: 100, start: 2000)]
        g.tick(); g.apply(good)
        expectEqual(r.sig.count(SIGSTOP, 101), 0, "child of a leftover entry must not be frozen")
        expect(r.sig.count(SIGCONT, 100) >= 3, "unresolved pid retried every tick")
        r.sig.failFor = []
        g.tick()
        expectEqual(g.unresolvedPIDs, [])
    }

    test("testNewProcessOfFrozenAppFrozenOnTick") {
        let r = Rig(); let g = r.guardian
        g.apply(bad)
        r.table.procs = r.table.procs + [gproc(300, "Claude", start: 3000)]
        g.tick()
        expectEqual(r.sig.count(SIGSTOP, 300), 1)
        r.clock.advance(by: 21)        // closed
        expectEqual(Set(r.sig.pids(SIGTERM)), [100, 200, 300])
        r.clock.advance(by: 30)
        r.table.procs = r.table.procs + [gproc(400, "Claude", start: 4000)]   // relaunch
        g.apply(bad)
        expectEqual(r.sig.count(SIGSTOP, 400), 1)
        expectEqual(g.frozenApps, ["claude"])
        expectEqual(deadline(g.state), .some(r.now.addingTimeInterval(20)), "relaunch gets a fresh countdown")
    }

    test("testConfigUpdateAppliesToNextFreeze") {
        let r = Rig(); let g = r.guardian
        g.apply(bad)
        var c = baseConfig(); c.grace = 50
        g.updateConfig(c)
        expectEqual(deadline(g.state), .some(r.now.addingTimeInterval(20)), "current freeze keeps its deadline")
        g.apply(good)
        g.apply(bad)
        expectEqual(deadline(g.state), .some(r.now.addingTimeInterval(50)))
        // Allowing the country re-evaluates the last observation right away.
        c.allow = AllowList(countries: ["NL", "DE"])
        g.updateConfig(c)
        expectEqual(g.state, .ok)
        // Removing an app from the list unfreezes it.
        g.apply(good)
        c.allow = AllowList(countries: ["NL"])
        g.updateConfig(c); g.apply(bad)
        expectEqual(g.frozenApps, ["claude", "telegram"])
        c.apps = ["claude"]
        g.updateConfig(c)
        expectEqual(g.frozenApps, ["claude"])
        expectEqual(r.freezer.frozenPIDs, [100])
    }

    test("testEventsLoggedWithCorrectKinds") {
        var c = baseConfig(); c.apps = ["claude"]
        let r = Rig(c); let g = r.guardian
        g.networkChanged()
        g.apply(good)
        g.apply(obs([], online: true, ipv6: true))
        r.clock.advance(by: 21)
        g.pause(for: 60)
        expectEqual(r.kinds(), [.networkChanged, .frozen, .resumed, .leak, .frozen, .closed, .paused])
        let f = r.events(.frozen)
        expectEqual(f.map { $0.detail }, ["networkChanged", "ipv6Leak"])
        expectEqual(f.map { $0.app }, ["claude", "claude"])
        expectEqual(r.events(.closed).map { $0.detail }, ["timeout"])
        for e in r.log.recent(limit: 100) { expect(!e.detail.contains("1.2.3.4"), "no IPs in history") }
        expectEqual(r.log.stats(), Stats(resumedInTime: 1, closed: 1, freezes: 2))
    }

    test("testNetworkChangedFreezesImmediately") {
        let r = Rig(); let g = r.guardian
        g.apply(good)
        let before = r.checks
        g.networkChanged()
        expectEqual(reason(g.state), .networkChanged)
        expectEqual(Set(r.sig.pids(SIGSTOP)), [100, 200])
        expectEqual(r.checks, before + 1)
        g.apply(good)
        expectEqual(g.state, .ok)
    }

    test("testOnChangeFiresOnEveryTransition") {
        var c = baseConfig(); c.appRules = ["telegram": AllowList(countries: ["DE"])]
        let r = Rig(c); let g = r.guardian
        g.apply(good)                       // ok -> frozen (telegram)
        g.apply(good)                       // no change
        g.apply(bad)                        // frozenApps changes: claude instead of telegram
        g.apply(obs([ans("9.9.9.9", "US"), ans("9.9.9.9", "US")]))   // both frozen
        g.apply(bad)                        // telegram resumes
        g.pause(for: 10)                    // paused
        r.clock.advance(by: 10)             // back: frozen (claude)
        g.closeNow()                        // closed
        expectEqual(r.states.count, 7, "\(r.states)")
        if r.states.count == 7 {
            expect(isFrozen(r.states[0]) && isFrozen(r.states[1]) && isFrozen(r.states[2]))
            if case .paused = r.states[4] {} else { expect(false, "\(r.states[4])") }
            if case .closed = r.states[6] {} else { expect(false, "\(r.states[6])") }
        }
    }

    test("testAllowCurrentIPReportsConfirmedIP") {
        let r = Rig(); let g = r.guardian
        g.allowCurrentIP()
        expectEqual(r.allowed, [], "nothing observed yet")
        g.apply(bad)
        g.allowCurrentIP()
        expectEqual(r.allowed, ["5.6.7.8"])
        g.apply(disagree)
        g.allowCurrentIP()
        expectEqual(r.allowed, ["5.6.7.8"], "unconfirmed IP is never offered")
        expect(isFrozen(g.state), "the guard does not change config itself")
    }

    test("testSafetyInvariantOkMeansResumedAndNoCloseWhileOffline") {
        var c = baseConfig(); c.appRules = ["telegram": AllowList(countries: ["DE"])]
        let r = Rig(c); let g = r.guardian
        let seq: [Observation] = [bad, good, offline, bad, disagree, offline, good, good, bad, offline, good]
        for (i, o) in seq.enumerated() {
            if i == 3 { r.table.failing = true }
            if i == 7 { r.table.failing = false }
            g.apply(o)
            if g.state == .ok {
                expect(r.freezer.frozenPIDs.isSubset(of: g.unresolvedPIDs), "step \(i): ok but frozen pids untracked")
                if !g.unresolvedPIDs.isEmpty { expect(g.frozenApps.isEmpty) }
            }
            if !o.online { expectEqual(r.clock.pendingCount, 0, "step \(i): close scheduled while offline") }
            r.clock.advance(by: 3)
        }
        g.updateConfig(baseConfig())   // drop telegram's DE-only rule: NL is fine for everyone
        g.apply(good)
        expectEqual(g.state, .ok)
        expectEqual(r.freezer.frozenPIDs, [])
    }

    test("testFreezerResumeSubsetLeavesOthersFrozen") {
        let r = Rig()
        r.freezer.freeze([gproc(100, "Claude"), gproc(200, "Telegram")])
        let left = r.freezer.resume([100])
        expectEqual(left, [])
        expectEqual(r.freezer.frozenPIDs, [200])
        expectEqual(r.sig.pids(SIGCONT), [100])
        expectEqual(Set(FreezeJournal(url: r.dir.appendingPathComponent("frozen.json")).load().keys), [200])
        r.table.failing = true
        expectEqual(r.freezer.resume([200]), [200])
        expectEqual(r.freezer.frozenPIDs, [200])
    }

    test("testCatalogPresetsAndCustomApps") {
        var c = Config.default
        c.apps = ["claude", "Cursor", "unknown-thing"]
        c.customApps = [CustomApp(name: "My Tool", match: "/MyTool.app/")]
        expectEqual(AppCatalog.appIDs(in: c), ["claude", "Cursor", "unknown-thing", "My Tool"])
        let claude = AppCatalog.matchers(for: "claude", in: c)
        expect(claude.contains { $0.matches(gproc(1, "Claude")) })
        expect(AppCatalog.matchers(for: "Cursor", in: c).contains { $0.matches(gproc(1, "Cursor")) })
        expectEqual(AppCatalog.matchers(for: "unknown-thing", in: c), [])
        expect(AppCatalog.matchers(for: "My Tool", in: c).contains { $0.matches(gproc(1, "MyTool")) })
        expect(!AppCatalog.matchers(for: "telegram", in: c).isEmpty)
        expect(AppCatalog.presets.contains { $0.group == AppCatalog.browsersForAI })
    }

    test("testFreezeFailureIsReportedAndStillClosedAtDeadline") {
        let r = Rig(unwritableJournal: true); let g = r.guardian
        g.apply(bad)
        expectEqual(r.sig.pids(SIGSTOP), [], "journal unwritable -> Freezer refuses to stop")
        expectEqual(reason(g.state), .freezeFailed, "not shown as plain frozen")
        expectEqual(g.frozenApps, [])
        expectEqual(g.freezeFailedApps, ["claude", "telegram"])
        expectEqual(Set(r.events(.leak).filter { $0.detail == "freezeFailed" }.compactMap { $0.app }),
                    ["claude", "telegram"])
        g.apply(bad)
        expectEqual(r.events(.leak).count, 2, "logged once per episode")
        expectEqual(deadline(g.state), .some(r.now.addingTimeInterval(20)), "countdown still runs")
        r.clock.advance(by: 19)
        expectEqual(r.sig.pids(SIGTERM), [])
        r.clock.advance(by: 2)
        expectEqual(Set(r.sig.pids(SIGTERM)), [100, 200], "running processes closed at the deadline")
        for pid: Int32 in [100, 200] {
            let s = r.sig.sent.filter { $0.pid == pid }.map { $0.sig }
            expect(s.firstIndex(of: SIGCONT).map { $0 < s.firstIndex(of: SIGTERM)! } ?? false, "SIGCONT before SIGTERM: \(s)")
        }
        expectEqual(Set(r.events(.closed).compactMap { $0.app }), ["claude", "telegram"])
        if case .closed = g.state {} else { expect(false, "\(g.state)") }
        expectEqual(g.freezeFailedApps, [])
    }

    test("testCloseNowClosesRunningProcessesAfterFailedFreeze") {
        let r = Rig(unwritableJournal: true); let g = r.guardian
        g.apply(bad)
        g.closeNow()
        expectEqual(Set(r.sig.pids(SIGTERM)), [100, 200])
        expectEqual(r.events(.closed).map { $0.detail }, ["closeNow", "closeNow"])
    }

    test("testRelaunchThatCannotBeFrozenReopensCountdown") {
        let r = Rig(unwritableJournal: true); let g = r.guardian
        g.apply(bad)
        r.clock.advance(by: 21)                       // both closed
        r.table.procs = [gproc(500, "Claude", start: 5000)]
        g.tick()
        expectEqual(g.freezeFailedApps, ["claude"])
        expectEqual(deadline(g.state), .some(r.now.addingTimeInterval(20)))
        r.clock.advance(by: 21)
        expectEqual(r.sig.count(SIGTERM, 500), 1)
    }

    test("testClaudeCodePresetDoesNotSelectDesktopApp") {
        var c = Config.default
        c.apps = ["claude-code"]
        let desktop = gproc(100, "Claude")
        let helper = ProcInfo(pid: 101, ppid: 100, name: "Claude Helper",
                              path: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper",
                              args: "", startTime: Date(timeIntervalSince1970: 1000), uid: me)
        let npmCLI = ProcInfo(pid: 300, ppid: 1, name: "node", path: "/usr/local/bin/node",
                              args: "node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js",
                              startTime: Date(timeIntervalSince1970: 1000), uid: me)
        let nativeCLI = ProcInfo(pid: 301, ppid: 1, name: "claude",
                                 path: "/Users/u/.local/share/claude/versions/1.0.0", args: "claude",
                                 startTime: Date(timeIntervalSince1970: 1000), uid: me)
        let all = [desktop, helper, npmCLI, nativeCLI]
        let code = AppCatalog.matchers(for: "claude-code", in: c)
        expectEqual(Set(code.flatMap { $0.select(from: all) }.map { $0.pid }), [300, 301])
        let desk = AppCatalog.matchers(for: "claude", in: c)
        expectEqual(Set(desk.flatMap { $0.select(from: all) }.map { $0.pid }), [100, 101])
    }

    test("testClaudeCodePresetIgnoresInstallersAndEditors") {
        var c = Config.default
        c.apps = ["claude-code"]
        func p(_ pid: Int32, _ name: String, _ path: String, _ args: String) -> ProcInfo {
            ProcInfo(pid: pid, ppid: 1, name: name, path: path, args: args, startTime: Date(timeIntervalSince1970: 1000), uid: me)
        }
        let yes = [
            p(1, "node", "/usr/local/bin/node", "node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"),
            p(2, "node", "/opt/homebrew/bin/node", "claude"),                                    // process.title = claude
            p(3, "node", "/Users/u/.nvm/versions/node/v20/bin/node", "node /Users/u/.npm-global/bin/claude --resume"),
            p(4, "claude", "/opt/homebrew/Caskroom/claude-code/1.0.0/claude", "claude"),
            p(5, "claude", "/usr/local/Caskroom/claude-code/2.0.1/claude", "claude -p hi"),
            p(6, "2.0.1", "/Users/u/.local/share/claude/versions/2.0.1", "claude"),
        ]
        let no = [
            p(10, "node", "/usr/local/bin/node", "node /usr/local/bin/npm i -g @anthropic-ai/claude-code"),
            p(11, "npm", "/usr/local/bin/npm", "npm install -g @anthropic-ai/claude-code"),
            p(12, "vim", "/usr/bin/vim", "vim /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"),
            p(13, "Electron", "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
              "/Applications/Visual Studio Code.app/Contents/MacOS/Electron /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"),
            p(14, "less", "/usr/bin/less", "less /Users/u/.npm-global/bin/claude"),
            p(15, "node", "/usr/local/bin/node", "node /usr/local/bin/claude-usage-report"),
            p(16, "Claude", "/Applications/Claude.app/Contents/MacOS/Claude", "/Applications/Claude.app/Contents/MacOS/Claude"),
        ]
        let m = AppCatalog.matchers(for: "claude-code", in: c)
        for x in yes { expect(m.contains { $0.matches(x) }, "should match \(x.args) @ \(x.path)") }
        for x in no { expect(!m.contains { $0.matches(x) }, "should NOT match \(x.args) @ \(x.path)") }
    }

    test("testUnsupportedReasonIsRussianText") {
        let r = AppCatalog.preset("safari")?.unsupported ?? ""
        expect(r.range(of: "[а-яА-Я]", options: .regularExpression) != nil, "reason shown in the UI as is: \(r)")
    }

    test("testSafariPresetUnsupportedAndNeverProtected") {
        var c = Config.default
        c.apps = ["safari", "claude"]
        let safari = AppCatalog.preset("safari")
        expect(safari?.unsupported?.isEmpty == false, "unsupported with a reason")
        expect(!AppCatalog.selectablePresets.contains { $0.id == "safari" })
        expectEqual(AppCatalog.appIDs(in: c), ["claude"])
        expectEqual(AppCatalog.matchers(for: "safari", in: c), [])
        c.apps = ["safari"]
        let r = Rig(c); let g = r.guardian
        g.apply(bad)
        expectEqual(g.state, .ok, "an unsupported app is not reported as protected")
    }

    test("testWallClockJumpDoesNotShortenOrExtendGrace") {
        let r = Rig(); let g = r.guardian
        g.apply(bad)
        r.clock.jumpWallClock(by: 3600)               // NTP step forward
        g.apply(bad)                                  // re-arms the timer
        expectEqual(deadline(g.state), .some(r.now.addingTimeInterval(20)), "remaining time unchanged")
        r.clock.advance(by: 19)
        expectEqual(r.sig.pids(SIGTERM), [], "no early close after a forward jump")
        r.clock.advance(by: 2)
        expectEqual(Set(r.sig.pids(SIGTERM)), [100, 200])

        let r2 = Rig(); let g2 = r2.guardian
        g2.apply(bad)
        r2.clock.jumpWallClock(by: -3600)             // backward
        g2.apply(bad)
        r2.clock.advance(by: 21)
        expectEqual(Set(r2.sig.pids(SIGTERM)), [100, 200], "a backward jump does not extend grace")
    }

    test("testNetworkChangedWhileOfflineStartsNoCountdown") {
        var c = baseConfig(); c.blockWhenOffline = false
        let r = Rig(c); let g = r.guardian
        g.apply(offline)
        expectEqual(g.state, .ok)
        g.networkChanged()
        expect(isFrozen(g.state))
        expectEqual(reason(g.state), .offline)
        expectEqual(deadline(g.state), .some(nil))
        expectEqual(r.clock.pendingCount, 0)
        r.clock.advance(by: 100)
        expectEqual(r.sig.pids(SIGTERM), [])
        g.apply(offline)                              // offline confirmed, block off: released again
        expectEqual(g.state, .ok)
        expectEqual(r.freezer.frozenPIDs, [])
        g.networkChanged()
        g.apply(bad)                                  // back online and wrong: real countdown
        expectEqual(deadline(g.state), .some(r.now.addingTimeInterval(20)))
    }

    test("testFakeClockFiresInOrderAndCancels") {
        let clock = FakeClock(start: Date(timeIntervalSince1970: 0))
        var fired: [Int] = []
        _ = clock.schedule(after: 5) { fired.append(5) }
        let c = clock.schedule(after: 3) { fired.append(3) }
        _ = clock.schedule(after: 1) { fired.append(1); _ = clock.schedule(after: 1) { fired.append(2) } }
        c.cancel()
        clock.advance(by: 4)
        expectEqual(fired, [1, 2])
        expectEqual(clock.now, Date(timeIntervalSince1970: 4))
        clock.advance(by: 1)
        expectEqual(fired, [1, 2, 5])
        expectEqual(clock.pendingCount, 0)
    }

    test("testDisplayedDeadlineIsWholeSecondsAndStable") {
        // Real clocks read `now` and `uptime` separately: the displayed deadline jitters by
        // microseconds. It must be rounded so onChange does not fire on every tick.
        let base = FakeClock(start: Date(timeIntervalSince1970: 1_800_000_000.25))
        let clock = JitterClock(base)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("safenet-guard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let table = GTable([gproc(100, "Claude")])
        let f = Freezer(table: table, signaler: GSignaler(), journal: dir.appendingPathComponent("frozen.json"),
                        selfPID: fakeSelf, myUID: me, pollInterval: 0.01)
        let g = Guard(config: baseConfig(), freezer: f, clock: clock, log: EventLog(url: dir.appendingPathComponent("e.jsonl")))
        var changes = 0
        g.onChange = { _ in changes += 1 }
        g.apply(bad)
        let first = changes
        guard case .frozen(_, _, let d?) = g.state else { expect(false, "not frozen: \(g.state)"); return }
        expectEqual(d.timeIntervalSince1970, d.timeIntervalSince1970.rounded(), "deadline must be whole seconds")
        for _ in 0..<5 { g.tick(); g.apply(bad) }
        expectEqual(changes, first, "jitter must not publish changes")
    }
}

/// Clock whose wall time drifts by a few microseconds on every read (like Date() vs systemUptime).
private final class JitterClock: Clock {
    let base: FakeClock
    private var n = 0.0
    init(_ b: FakeClock) { base = b }
    var now: Date { n += 1; return base.now.addingTimeInterval(n * 0.000_003) }
    var uptime: TimeInterval { base.uptime }
    func schedule(after: TimeInterval, _ f: @escaping () -> Void) -> Cancellable { base.schedule(after: after, f) }
}
