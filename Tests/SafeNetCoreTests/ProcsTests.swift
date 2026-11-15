import Foundation
import Darwin
@testable import SafeNetCore

// All tests except testRealSleepProcessFreezeResumeClose use a fake ProcessTable and a
// fake Signaler: they never signal a real process.

private let me = getuid()
private let fakeSelf: Int32 = 7   // fake "SafeNet" pid, never collides with fake app pids

private func proc(_ pid: Int32, _ name: String, path: String? = nil, args: String = "",
                  ppid: Int32 = 1, start: Double = 1000, uid: uid_t = me) -> ProcInfo {
    ProcInfo(pid: pid, ppid: ppid, name: name,
             path: path ?? "/Applications/\(name).app/Contents/MacOS/\(name)",
             args: args.isEmpty ? (path ?? "/Applications/\(name).app/Contents/MacOS/\(name)") : args,
             startTime: Date(timeIntervalSince1970: start), uid: uid)
}

private final class FakeTable: ProcessTable {
    private let lock = NSLock()
    private var _procs: [ProcInfo]
    init(_ p: [ProcInfo]) { _procs = p }
    var procs: [ProcInfo] {
        get { lock.lock(); defer { lock.unlock() }; return _procs }
        set { lock.lock(); _procs = newValue; lock.unlock() }
    }
    func list() -> [ProcInfo] { procs }
    func remove(_ pid: Int32) { procs = procs.filter { $0.pid != pid } }
}

private final class FakeSignaler: Signaler {
    private let lock = NSLock()
    private var _sent: [(sig: Int32, pid: Int32)] = []
    var onSend: ((Int32, Int32) -> Void)?
    var sent: [(sig: Int32, pid: Int32)] { lock.lock(); defer { lock.unlock() }; return _sent }
    func send(_ sig: Int32, to pid: Int32) -> Bool {
        lock.lock(); _sent.append((sig, pid)); lock.unlock()
        onSend?(sig, pid)
        return true
    }
    func pids(_ sig: Int32) -> [Int32] { sent.filter { $0.sig == sig }.map { $0.pid } }
    func signals(to pid: Int32) -> [Int32] { sent.filter { $0.pid == pid }.map { $0.sig } }
}

private func tempJournal() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("safenet-procs-\(UUID().uuidString)", isDirectory: true)
    return dir.appendingPathComponent("frozen.json")
}

private func journalPIDs(_ url: URL) -> Set<Int32> {
    Set(FreezeJournal(url: url).load().keys)
}

private func makeFreezer(_ t: FakeTable, _ s: FakeSignaler, _ j: URL) -> Freezer {
    Freezer(table: t, signaler: s, journal: j, selfPID: fakeSelf, myUID: me, pollInterval: 0.02)
}

private final class Box<T> { var value: T? }
private func awaitAsync(_ op: @escaping () async -> Void) {
    let sem = DispatchSemaphore(value: 0)
    Task { await op(); sem.signal() }
    sem.wait()
}

/// Reads the scheduler status of a real pid (4 == SSTOP).
private func realStatus(_ pid: Int32) -> Int8? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var k = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &k, &size, nil, 0) == 0, size > 0, k.kp_proc.p_pid == pid else { return nil }
    return k.kp_proc.p_stat
}
private func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if cond() { return true }; usleep(20_000) }
    return cond()
}

func registerProcsTests() {
    // MARK: matching

    test("testMatchByName") {
        let tg = proc(10, "Telegram")
        expect(AppMatcher(match: "Telegram").matches(tg))
        expect(AppMatcher(match: "telegram").matches(tg), "case-insensitive")
        expect(AppMatcher(match: "  Telegram ").matches(tg), "trimmed")
        expect(!AppMatcher(match: "Telegra").matches(tg), "name is equality, not substring")
        expect(!AppMatcher(match: "Telegram Helper").matches(tg))
        // kernel name truncated: executable basename from path still matches
        let long = ProcInfo(pid: 11, ppid: 1, name: "Some Very Long Application Na",
                            path: "/Applications/X.app/Contents/MacOS/Some Very Long Application Name",
                            args: "", startTime: Date(), uid: me)
        expect(AppMatcher(match: "some very long application name").matches(long))
        expect(AppMatcher(CustomApp(name: "TG", match: "Telegram")).matches(tg))
    }

    test("testMatchByPathFragment") {
        let c = proc(20, "Claude")
        expect(AppMatcher(match: "Claude.app/").matches(c))
        expect(AppMatcher(match: "/applications/claude.app").matches(c), "path match case-insensitive")
        expect(!AppMatcher(match: "/Applications/Other.app").matches(c))
        let nopath = ProcInfo(pid: 21, ppid: 1, name: "Claude", path: "", args: "", startTime: Date(), uid: me)
        expect(!AppMatcher(match: "Claude.app/").matches(nopath), "unknown path never matches a path rule")
    }

    test("testMatchByArgsFragment") {
        let p = proc(30, "python3", path: "/usr/bin/python3", args: "/usr/bin/python3 /Users/x/bot.py --profile work")
        expect(AppMatcher(match: "args:bot.py").matches(p))
        expect(AppMatcher(match: "args: --profile work").matches(p), "fragment trimmed")
        expect(AppMatcher(match: "ARGS:bot.py").matches(p), "prefix case-insensitive")
        expect(!AppMatcher(match: "args:other.py").matches(p))
        expect(!AppMatcher(match: "args:bot.py").matches(proc(31, "python3", path: "/usr/bin/python3", args: "/usr/bin/python3")))
    }

    test("testEmptyMatchStringNeverMatches") {
        let all = [proc(40, "A"), proc(41, "B", args: "x y z"),
                   ProcInfo(pid: 42, ppid: 1, name: "", path: "", args: "", startTime: Date(), uid: me)]
        for m in ["", "   ", "\t\n", "args:", "args:   ", "/", " // ", "ARGS:"] {
            let matcher = AppMatcher(match: m)
            for p in all { expect(!matcher.matches(p), "'\(m)' must not match \(p.name)") }
            expect(matcher.select(from: all).isEmpty, "'\(m)' selects nothing")
        }
    }

    // MARK: deny list

    test("testDenyListNeverFrozen") {
        let protectedProcs = [
            proc(1, "launchd", path: "/sbin/launchd", ppid: 0, uid: 0),
            proc(300, "launchd", path: "/sbin/launchd"),
            proc(301, "WindowServer", path: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer"),
            proc(302, "Finder", path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"),
            proc(303, "Dock", path: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"),
            proc(304, "loginwindow", path: "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"),
            proc(305, "trustd", path: "/usr/libexec/trustd"),
            proc(306, "Telegram", uid: me + 1),                   // other user
            proc(307, "Telegram", uid: 0),                        // root
            proc(fakeSelf, "Telegram"),                           // SafeNet itself (by pid)
            proc(308, "SafeNet", path: "/Applications/SafeNet.app/Contents/MacOS/SafeNet"),
            proc(309, "Finder", path: "/Users/x/Finder"),         // deny by name anywhere
            proc(0, "kernel_task", path: "/kernel", uid: 0),
            ProcInfo(pid: 310, ppid: 1, name: "Telegram", path: "", args: "", startTime: Date(), uid: me), // path unknown
        ]
        for p in protectedProcs {
            expect(isProtected(p, selfPID: fakeSelf, myUID: me), "\(p.pid) \(p.name) must be protected")
        }
        expect(!isProtected(proc(400, "Telegram"), selfPID: fakeSelf, myUID: me), "ordinary user app is not protected")

        let t = FakeTable(protectedProcs), s = FakeSignaler(), j = tempJournal()
        let f = makeFreezer(t, s, j)
        let frozen = f.freeze(protectedProcs)
        expect(frozen.isEmpty)
        expect(s.sent.isEmpty, "no signal to protected processes: \(s.sent)")
        expect(journalPIDs(j).isEmpty)
        // a matcher naming a protected process selects it, but the freezer still refuses
        expect(f.freezeNewlyStarted(matching: [AppMatcher(match: "Finder"), AppMatcher(match: "launchd")]).isEmpty)
        expect(s.sent.isEmpty)
    }

    // MARK: freeze / journal

    test("testFreezeWritesJournalBeforeSignal") {
        let app = proc(500, "Telegram")
        let t = FakeTable([app]), s = FakeSignaler(), j = tempJournal()
        var journaledAtSignal: Set<Int32>? = nil
        s.onSend = { sig, _ in if sig == SIGSTOP { journaledAtSignal = journalPIDs(j) } }
        let f = makeFreezer(t, s, j)
        let frozen = f.freeze([app])
        expectEqual(frozen.map { $0.pid }, [500])
        expectEqual(s.pids(SIGSTOP), [500])
        expectEqual(journaledAtSignal, [500], "journal on disk must already contain the pid when SIGSTOP is sent")
        let entries = FreezeJournal(url: j).load()
        expectEqual(entries[500], 1000, "journal stores start time")
        expectEqual(f.frozenPIDs, [500])
        // freezing again is a no-op
        expect(f.freeze([app]).isEmpty)
        expectEqual(s.pids(SIGSTOP), [500])
    }

    test("testFreezeRefusesWhenJournalUnwritable") {
        let app = proc(510, "Telegram")
        let t = FakeTable([app]), s = FakeSignaler()
        let j = URL(fileURLWithPath: "/dev/null/nope/frozen.json")
        let f = makeFreezer(t, s, j)
        expect(f.freeze([app]).isEmpty)
        expect(s.sent.isEmpty, "no SIGSTOP without a durable journal")
        expect(f.frozenPIDs.isEmpty)
    }

    test("testFreezeSkipsStaleProcInfo") {
        // caller's snapshot is stale: pid 520 now belongs to a different process
        let t = FakeTable([proc(520, "Other", start: 2000)]), s = FakeSignaler(), j = tempJournal()
        let f = makeFreezer(t, s, j)
        expect(f.freeze([proc(520, "Telegram", start: 1000)]).isEmpty)
        expect(f.freeze([proc(521, "Gone")]).isEmpty, "process not in table")
        expect(s.sent.isEmpty)
    }

    test("testResumeAllSendsSIGCONTAndClearsJournal") {
        let a = proc(600, "Telegram"), b = proc(601, "Claude")
        let t = FakeTable([a, b]), s = FakeSignaler(), j = tempJournal()
        let f = makeFreezer(t, s, j)
        f.freeze([a, b])
        expectEqual(Set(s.pids(SIGSTOP)), [600, 601])
        f.resumeAll()
        expectEqual(Set(s.pids(SIGCONT)), [600, 601])
        expect(journalPIDs(j).isEmpty, "journal cleared")
        expect(f.frozenPIDs.isEmpty)
        f.resumeAll()
        expectEqual(s.pids(SIGCONT).count, 2, "second resume sends nothing")
    }

    test("testReconcileResumesJournaledPIDs") {
        let a = proc(700, "Telegram"), b = proc(701, "Claude")
        let t = FakeTable([a, b]), j = tempJournal()
        let s1 = FakeSignaler()
        let crashed = makeFreezer(t, s1, j)
        crashed.freeze([a, b])
        // app "crashes"; a new instance starts with the same journal
        let s2 = FakeSignaler()
        let f = makeFreezer(t, s2, j)
        f.reconcile()
        expectEqual(Set(s2.pids(SIGCONT)), [700, 701])
        expect(s2.pids(SIGSTOP).isEmpty)
        expect(journalPIDs(j).isEmpty)
        // a missing journal is fine too
        let s3 = FakeSignaler()
        makeFreezer(t, s3, tempJournal()).reconcile()
        expect(s3.sent.isEmpty)
    }

    test("testLeftoverJournalEntriesSurviveNewFreeze") {
        // the previous run left pid 710 frozen; the new run freezes 711 before reconciling:
        // 710 must stay in the journal (otherwise it could never be resumed)
        let a = proc(710, "Telegram"), b = proc(711, "Claude")
        let t = FakeTable([a, b]), j = tempJournal()
        makeFreezer(t, FakeSignaler(), j).freeze([a])
        let s = FakeSignaler()
        let f = makeFreezer(t, s, j)
        f.freeze([b])
        expectEqual(journalPIDs(j), [710, 711])
        f.resumeAll()
        expectEqual(Set(s.pids(SIGCONT)), [710, 711])
    }

    test("testResumeSkipsPidWithDifferentStartTime") {
        let a = proc(800, "Telegram", start: 1000), b = proc(801, "Claude", start: 1000)
        let t = FakeTable([a, b]), s = FakeSignaler(), j = tempJournal()
        let f = makeFreezer(t, s, j)
        f.freeze([a, b])
        // Telegram exited, its pid was reused by an unrelated process
        t.procs = [proc(800, "Unrelated", start: 5000), b]
        f.resumeAll()
        expectEqual(s.pids(SIGCONT), [801], "SIGCONT must not reach the reused pid")
        expect(journalPIDs(j).isEmpty)
        // same through reconcile after a crash
        let t2 = FakeTable([a]), s2 = FakeSignaler(), j2 = tempJournal()
        makeFreezer(t2, FakeSignaler(), j2).freeze([a])
        t2.procs = [proc(800, "Unrelated", start: 1000.5)]
        let f2 = makeFreezer(t2, s2, j2)
        f2.reconcile()
        expect(s2.sent.isEmpty)
    }

    test("testCorruptedJournalTreatedAsEmpty") {
        let j = tempJournal()
        try FileManager.default.createDirectory(at: j.deletingLastPathComponent(), withIntermediateDirectories: true)
        for garbage in ["{not json", "", "[1,2,3]", "{\"version\":1,\"entries\":[{\"pid\":\"x\"}]}",
                        "{\"version\":1,\"entries\":[{\"pid\":-1,\"start\":5},{\"pid\":1,\"start\":5},{\"pid\":0,\"start\":5}]}"] {
            try Data(garbage.utf8).write(to: j)
            expect(FreezeJournal(url: j).load().isEmpty, "garbage: \(garbage)")
            let s = FakeSignaler()
            let f = makeFreezer(FakeTable([proc(900, "Telegram")]), s, j)
            f.reconcile()
            expect(s.sent.isEmpty)
        }
        try Data("garbage".utf8).write(to: j)
        let app = proc(901, "Telegram")
        let s = FakeSignaler()
        let f = makeFreezer(FakeTable([app]), s, j)
        expectEqual(f.freeze([app]).map { $0.pid }, [901], "freeze still works over a corrupted journal")
        expectEqual(journalPIDs(j), [901], "journal rewritten valid")
    }

    // MARK: helpers / new processes

    test("testHelpersFrozenTogether") {
        let main = proc(1000, "Claude")
        let helper = proc(1001, "Claude Helper (Renderer)",
                          path: "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)",
                          ppid: 1000)
        let xpc = proc(1002, "ShipIt", path: "/Applications/Claude.app/Contents/Frameworks/Squirrel.framework/Resources/ShipIt", ppid: 1)
        let child = proc(1003, "node", path: "/usr/local/bin/node", ppid: 1000)
        let grandchild = proc(1004, "sh", path: "/bin/sh", ppid: 1003)
        let sysChild = proc(1005, "trustd", path: "/usr/libexec/trustd", ppid: 1000)
        let sysGrandchild = proc(1006, "x", path: "/usr/local/bin/x", ppid: 1005)
        let unrelated = proc(1007, "Telegram")
        let all = [main, helper, xpc, child, grandchild, sysChild, sysGrandchild, unrelated]

        let sel = AppMatcher(match: "Claude").select(from: all).map { $0.pid }
        expectEqual(Set(sel), [1000, 1001, 1002], "matched process plus processes inside the same .app bundle")

        let t = FakeTable(all), s = FakeSignaler(), j = tempJournal()
        let f = makeFreezer(t, s, j)
        f.freeze([main])
        expectEqual(Set(s.pids(SIGSTOP)), [1000, 1001, 1003, 1004], "descendants frozen with the app; protected ones and their subtree skipped")
        f.freezeNewlyStarted(matching: [AppMatcher(match: "Claude")])
        expectEqual(Set(s.pids(SIGSTOP)), [1000, 1001, 1002, 1003, 1004])
        expect(!s.pids(SIGSTOP).contains(1007))

        // args: rule does not pull in the whole bundle (Python.app would drag every python in)
        let py = proc(1100, "Python", path: "/Library/Frameworks/Python.framework/Versions/3.11/Resources/Python.app/Contents/MacOS/Python",
                      args: "python3 bot.py")
        let py2 = proc(1101, "Python", path: py.path, args: "python3 other.py")
        expectEqual(AppMatcher(match: "args:bot.py").select(from: [py, py2]).map { $0.pid }, [1100])
    }

    test("testNewMatchingProcessGetsFrozenOnNextTick") {
        let main = proc(1200, "Telegram")
        let t = FakeTable([main, proc(1201, "Claude")]), s = FakeSignaler(), j = tempJournal()
        let f = makeFreezer(t, s, j)
        let m = [AppMatcher(match: "Telegram")]
        f.freezeNewlyStarted(matching: m)
        expectEqual(s.pids(SIGSTOP), [1200])
        // tick with nothing new: nothing re-sent
        expect(f.freezeNewlyStarted(matching: m).isEmpty)
        expectEqual(s.pids(SIGSTOP), [1200])
        // a second instance / relaunch appears while frozen
        t.procs = t.procs + [proc(1202, "Telegram", start: 3000),
                             proc(1203, "Telegram Helper", path: "/Applications/Telegram.app/Contents/Helpers/Telegram Helper", ppid: 1)]
        let new = f.freezeNewlyStarted(matching: m)
        expectEqual(Set(new.map { $0.pid }), [1202, 1203])
        expectEqual(Set(s.pids(SIGSTOP)), [1200, 1202, 1203])
        expectEqual(journalPIDs(j), [1200, 1202, 1203])
        expect(!s.pids(SIGSTOP).contains(1201))
        // a child spawned by a frozen process is caught even without a matcher
        t.procs = t.procs + [proc(1204, "zsh", path: "/bin/zsh", ppid: 1200)]
        f.freezeNewlyStarted(matching: [])
        expect(s.pids(SIGSTOP).contains(1204))
    }

    // MARK: close

    test("testCloseSendsTerminateThenKillAfterTimeout") {
        let stubborn = proc(1300, "Telegram")
        let t = FakeTable([stubborn]), s = FakeSignaler(), j = tempJournal()
        let f = makeFreezer(t, s, j)
        f.freeze([stubborn])
        s.onSend = { sig, pid in if sig == SIGKILL { t.remove(pid) } }
        let start = Date()
        awaitAsync { await f.close([stubborn], gentle: 0.3) }
        let took = Date().timeIntervalSince(start)
        expectEqual(s.signals(to: 1300), [SIGSTOP, SIGCONT, SIGTERM, SIGKILL])
        expect(took >= 0.28, "waited the gentle period: \(took)")
        expect(took < 2, "did not hang: \(took)")
        expect(journalPIDs(j).isEmpty, "closed pid removed from journal")
        expect(f.frozenPIDs.isEmpty)
    }

    test("testCloseSendsSIGCONTBeforeSIGTERM") {
        let polite = proc(1400, "Telegram"), helper = proc(1401, "Telegram Helper", path: "/x/helper", ppid: 1400)
        let t = FakeTable([polite, helper]), s = FakeSignaler(), j = tempJournal()
        let f = makeFreezer(t, s, j)
        f.freeze([polite])
        // the process exits on SIGTERM (only possible because it got SIGCONT first)
        s.onSend = { sig, pid in if sig == SIGTERM { t.remove(pid) } }
        let start = Date()
        awaitAsync { await f.close([polite], gentle: 5) }
        expectEqual(s.signals(to: 1400), [SIGSTOP, SIGCONT, SIGTERM], "no SIGKILL when it exits")
        expectEqual(s.signals(to: 1401), [SIGSTOP, SIGCONT, SIGTERM], "helpers closed with the app")
        expect(Date().timeIntervalSince(start) < 1, "returns as soon as everything exited")
        expect(journalPIDs(j).isEmpty)
    }

    test("testCloseNeverSignalsProtectedProcesses") {
        let finder = proc(1500, "Finder", path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder")
        let other = proc(1501, "Telegram", uid: me + 1)
        let me1 = proc(fakeSelf, "SafeNet")
        let launchd = proc(1, "launchd", path: "/sbin/launchd", ppid: 0, uid: 0)
        let reused = proc(1502, "Telegram", start: 1000)
        let t = FakeTable([finder, other, me1, launchd, proc(1502, "Unrelated", start: 9999)])
        let s = FakeSignaler()
        let f = makeFreezer(t, s, tempJournal())
        awaitAsync { await f.close([finder, other, me1, launchd, reused], gentle: 0.1) }
        expect(s.sent.isEmpty, "close must not signal protected or reused pids: \(s.sent)")
    }

    test("testCloseZeroGentleKillsImmediately") {
        let p = proc(1600, "Telegram")
        let t = FakeTable([p]), s = FakeSignaler()
        s.onSend = { sig, pid in if sig == SIGKILL { t.remove(pid) } }
        let f = makeFreezer(t, s, tempJournal())
        awaitAsync { await f.close([p], gentle: 0) }
        expectEqual(s.signals(to: 1600), [SIGCONT, SIGTERM, SIGKILL])
    }

    // MARK: watchdog

    test("testWatchdogResumesWhenParentDies") {
        let a = proc(1700, "Telegram"), b = proc(1701, "Claude", start: 1000)
        let t = FakeTable([a, b]), j = tempJournal()
        makeFreezer(t, FakeSignaler(), j).freeze([a, b])
        t.procs = [a, proc(1701, "Reused", start: 4242)]
        let s = FakeSignaler()
        var checks = 0
        Freezer.watchdog(journal: j, table: t, signaler: s, selfPID: fakeSelf, myUID: me,
                         isParentAlive: { checks += 1; return checks < 3 },
                         wait: { expect(s.sent.isEmpty, "nothing resumed while parent alive") })
        expectEqual(checks, 3)
        expectEqual(s.pids(SIGCONT), [1700], "resumes journaled pids with matching start time only")
        expect(journalPIDs(j).isEmpty)
    }

    test("testRunWatchdogReturnsForDeadParent") {
        // nonexistent parent + empty journal: must return promptly and signal nothing
        let j = tempJournal()
        let start = Date()
        Freezer.runWatchdog(parent: 2_000_000_000, journal: j)
        expect(Date().timeIntervalSince(start) < 2)
    }

    test("testKillSignalerRefusesDangerousPids") {
        let k = KillSignaler()
        expect(!k.send(0, to: 0), "pid 0 = own process group")
        expect(!k.send(0, to: -1), "pid -1 = every process")
        expect(!k.send(0, to: -500), "negative = process group")
        expect(!k.send(0, to: 1), "launchd")
        expect(k.send(0, to: getpid()), "signal 0 probe to self works")
    }

    // MARK: real process (the only test that signals anything real: its own child)

    test("testRealSleepProcessFreezeResumeClose") {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let pid = child.processIdentifier
        defer {
            if child.isRunning { kill(pid, SIGCONT); kill(pid, SIGKILL); child.waitUntilExit() }
        }
        let table = SystemProcessTable()
        let all = table.list()
        expect(all.count > 10, "lists system processes: \(all.count)")
        guard let info = all.first(where: { $0.pid == pid }) else {
            expect(false, "spawned child not listed"); return
        }
        expectEqual(info.name, "sleep")
        expectEqual(info.path, "/bin/sleep")
        expectEqual(info.args, "/bin/sleep 30")
        expectEqual(info.uid, getuid())
        expectEqual(info.ppid, getpid())
        expect(abs(info.startTime.timeIntervalSinceNow) < 10, "start time recent: \(info.startTime)")
        expect(AppMatcher(match: "args:sleep 30").matches(info))
        expect(!isProtected(info, selfPID: getpid(), myUID: getuid()))
        expect(all.contains { $0.pid == getpid() }, "lists itself")
        if let ld = all.first(where: { $0.pid == 1 }) {
            expect(isProtected(ld, selfPID: getpid(), myUID: getuid()), "real launchd protected")
        }

        let j = tempJournal()
        let f = Freezer(table: table, signaler: KillSignaler(), journal: j)
        expectEqual(f.freeze([info]).map { $0.pid }, [pid])
        expect(waitUntil(2) { realStatus(pid) == 4 }, "child stopped (status \(String(describing: realStatus(pid))))")
        f.resumeAll()
        expect(waitUntil(2) { realStatus(pid) != 4 }, "child running again")
        expect(child.isRunning)
        f.freeze([info])
        expect(waitUntil(2) { realStatus(pid) == 4 })
        awaitAsync { await f.close([info], gentle: 3) }
        expect(waitUntil(3) { !child.isRunning }, "stopped child terminated by close")
        expectEqual(child.terminationReason, .uncaughtSignal)
        expectEqual(child.terminationStatus, SIGTERM, "exited from SIGTERM, not SIGKILL")
        expect(journalPIDs(j).isEmpty)
    }
}
