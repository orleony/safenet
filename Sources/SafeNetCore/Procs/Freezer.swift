import Foundation
import Darwin

public protocol Signaler {
    /// Sends `sig` to `pid`; true on success.
    func send(_ sig: Int32, to pid: Int32) -> Bool
}

/// Real signaler (kill(2)). Refuses pid <= 1: kill(0) / kill(-1) / kill(-pgid) would hit
/// whole process groups or every process of the user, and pid 1 is launchd.
public struct KillSignaler: Signaler {
    public init() {}
    public func send(_ sig: Int32, to pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        return kill(pid, sig) == 0
    }
}

// MARK: - Journal

/// On-disk list of frozen processes `(pid, startTime)`. Written atomically and fsynced
/// before any SIGSTOP. A missing or corrupted file reads as empty.
struct FreezeJournal {
    let url: URL

    private struct File: Codable { var version: Int; var entries: [Entry] }
    private struct Entry: Codable { var pid: Int32; var start: Double }

    func load() -> [Int32: Double] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [:] }
        var out: [Int32: Double] = [:]
        for e in file.entries where e.pid > 1 && e.start.isFinite { out[e.pid] = e.start }
        return out
    }

    struct WriteError: Error { let step: String; let code: Int32 }

    func save(_ entries: [Int32: Double]) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = File(version: 1, entries: entries.keys.sorted().map { Entry(pid: $0, start: entries[$0]!) })
        let data = try JSONEncoder().encode(file)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw WriteError(step: "open", code: errno) }
        var ok = data.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 { if errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
        if ok { ok = fsync(fd) == 0 }
        let err = errno
        close(fd)
        guard ok else { unlink(tmp.path); throw WriteError(step: "write", code: err) }
        guard rename(tmp.path, url.path) == 0 else {
            let e = errno; unlink(tmp.path); throw WriteError(step: "rename", code: e)
        }
        let dfd = open(dir.path, O_RDONLY)
        if dfd >= 0 { _ = fsync(dfd); close(dfd) }
    }
}

// MARK: - Freezer

/// Freezes (SIGSTOP), resumes (SIGCONT) and closes processes. Every signal goes through
/// `isProtected` against the *current* process table, and every resume/kill checks that the
/// pid still has the journaled start time (pid reuse safety). Thread-safe.
public final class Freezer {
    private let table: ProcessTable
    private let signaler: Signaler
    private let journal: FreezeJournal
    private let selfPID: Int32
    private let myUID: uid_t
    private let pollInterval: TimeInterval
    private let lock = NSLock()
    /// pid -> start time (seconds since 1970) of processes this freezer stopped; mirrored on disk.
    private var frozen: [Int32: Double]

    public convenience init(table: ProcessTable, signaler: Signaler, journal: URL) {
        self.init(table: table, signaler: signaler, journal: journal, selfPID: getpid(), myUID: getuid())
    }

    public init(table: ProcessTable, signaler: Signaler, journal: URL,
                selfPID: Int32, myUID: uid_t, pollInterval: TimeInterval = 0.1) {
        self.table = table; self.signaler = signaler; self.journal = FreezeJournal(url: journal)
        self.selfPID = selfPID; self.myUID = myUID
        self.pollInterval = max(0.01, pollInterval)
        // Keep leftovers of a previous run so a new freeze never drops them from the journal.
        self.frozen = self.journal.load()
    }

    public var frozenPIDs: Set<Int32> { withLock { Set(frozen.keys) } }

    /// Freezes the given processes plus their descendants. Stale entries (pid now has another
    /// start time, or is gone) and protected processes are skipped; already frozen ones are not
    /// re-signalled. The journal is durably written before the first SIGSTOP; if it cannot be
    /// written nothing is frozen. Returns the processes actually stopped.
    @discardableResult
    public func freeze(_ procs: [ProcInfo]) -> [ProcInfo] {
        withLock {
            let current = table.list()
            let byPID = Self.index(current)
            var roots: [Int32: ProcInfo] = [:]
            for p in procs {
                guard let c = byPID[p.pid], Self.same(c.startTime, p.startTime), !protected(c) else { continue }
                roots[c.pid] = c
            }
            // Children of processes frozen earlier also count (helpers spawned later).
            for (pid, start) in frozen {
                if let c = byPID[pid], Self.same(c.startTime, start), !protected(c) { roots[pid] = c }
            }
            let targets = withDescendants(roots, in: current)
            let new = targets.values
                .filter { p in frozen[p.pid].map { !Self.same(p.startTime, $0) } ?? true }
                .sorted { $0.pid < $1.pid }
            guard !new.isEmpty else { return [] }

            var next = frozen
            for p in new { next[p.pid] = p.startTime.timeIntervalSince1970 }
            do { try journal.save(next) } catch { return [] }   // no durable journal -> no SIGSTOP
            frozen = next

            var done: [ProcInfo] = []
            for p in new {
                if signaler.send(SIGSTOP, to: p.pid) { done.append(p) } else { frozen[p.pid] = nil }
            }
            if done.count != new.count { try? journal.save(frozen) }
            return done
        }
    }

    /// Per-tick catch-up while apps are frozen: freezes processes of these apps that appeared
    /// since (relaunch, second instance, helpers) and children of already frozen processes.
    @discardableResult
    public func freezeNewlyStarted(matching matchers: [AppMatcher]) -> [ProcInfo] {
        let all = table.list()
        var seen = Set<Int32>(), candidates: [ProcInfo] = []
        for m in matchers { for p in m.select(from: all) where seen.insert(p.pid).inserted { candidates.append(p) } }
        return freeze(candidates)
    }

    /// Sends SIGCONT to every journaled process whose identity (pid + start time + uid) still
    /// matches. An entry leaves the journal only when SIGCONT succeeded or the process is
    /// verifiably gone / replaced; everything else stays journaled for the next retry
    /// (reconcile, quit, watchdog). Returns the pids still journaled.
    @discardableResult
    public func resumeAll() -> Set<Int32> {
        withLock {
            var entries = journal.load()
            for (pid, start) in frozen { entries[pid] = start }
            let remaining = Self.resume(entries, table: table, signaler: signaler, selfPID: selfPID, myUID: myUID)
            frozen = remaining
            try? journal.save(remaining)
            return Set(remaining.keys)
        }
    }

    /// Startup recovery: resumes whatever a previous run left in the journal.
    @discardableResult
    public func reconcile() -> Set<Int32> { resumeAll() }

    /// Closes the processes and their descendants: SIGCONT (a stopped process cannot handle
    /// SIGTERM), SIGTERM, wait up to `gentle` seconds, then SIGKILL the survivors.
    public func close(_ procs: [ProcInfo], gentle: TimeInterval) async {
        let targets: [ProcInfo] = withLock {
            let current = table.list()
            let byPID = Self.index(current)
            var roots: [Int32: ProcInfo] = [:]
            for p in procs {
                guard let c = byPID[p.pid], Self.same(c.startTime, p.startTime), !protected(c) else { continue }
                roots[c.pid] = c
            }
            let all = withDescendants(roots, in: current).values.sorted { $0.pid < $1.pid }
            for p in all {
                _ = signaler.send(SIGCONT, to: p.pid)
                _ = signaler.send(SIGTERM, to: p.pid)
            }
            return all
        }
        guard !targets.isEmpty else { return }

        let deadline = Date().addingTimeInterval(gentle.isFinite ? max(0, gentle) : 0)
        while true {
            let alive = survivors(targets)
            if alive.isEmpty { break }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 {
                withLock {
                    for p in survivors(targets) { _ = signaler.send(SIGKILL, to: p.pid) }
                }
                break
            }
            try? await Task.sleep(nanoseconds: UInt64(min(pollInterval, left) * 1_000_000_000))
        }
        withLock {
            var changed = false
            for p in targets where frozen[p.pid].map({ Self.same(p.startTime, $0) }) == true {
                frozen[p.pid] = nil; changed = true
            }
            if changed { try? journal.save(frozen) }
        }
    }

    // MARK: Watchdog

    /// Watchdog mode (`SafeNet --watchdog <parentPID>`, started by the app in Task 9).
    /// Blocks while `parent` lives (kqueue NOTE_EXIT plus a 0.5 s liveness poll that also
    /// notices re-parenting, which catches pid reuse), then resumes every journaled process
    /// whose start time still matches, clears the journal and returns; the caller then exits.
    public static func runWatchdog(parent: Int32, journal: URL) {
        let wasChild = getppid() == parent
        let alive: () -> Bool = {
            if parent <= 1 { return false }
            if wasChild && getppid() != parent { return false }
            if kill(parent, 0) == 0 { return true }
            return errno == EPERM
        }
        let kq = kqueue()
        if kq >= 0 {
            var ev = kevent(ident: UInt(UInt32(bitPattern: parent)), filter: Int16(EVFILT_PROC),
                            flags: UInt16(EV_ADD | EV_ONESHOT), fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
            _ = kevent(kq, &ev, 1, nil, 0, nil)   // fails with ESRCH if already gone; the poll handles it
        }
        let wait: () -> Void = {
            if kq >= 0 {
                var out = kevent()
                var ts = timespec(tv_sec: 0, tv_nsec: 500_000_000)
                _ = kevent(kq, nil, 0, &out, 1, &ts)
            } else {
                usleep(500_000)
            }
        }
        watchdog(journal: journal, table: SystemProcessTable(), signaler: KillSignaler(),
                 selfPID: getpid(), myUID: getuid(), isParentAlive: alive, wait: wait)
        if kq >= 0 { Darwin.close(kq) }
    }

    /// Testable core of the watchdog.
    /// After the parent died, retries unresolved entries up to `retries` times (one `wait()`
    /// apart, ~0.5 s each in production), keeping them journaled for the next app start.
    static func watchdog(journal url: URL, table: ProcessTable, signaler: Signaler, selfPID: Int32, myUID: uid_t,
                         isParentAlive: () -> Bool, wait: () -> Void, retries: Int = 20) {
        while isParentAlive() { wait() }
        let j = FreezeJournal(url: url)
        var entries = j.load()
        var attempt = 0
        while !entries.isEmpty {
            let remaining = resume(entries, table: table, signaler: signaler, selfPID: selfPID, myUID: myUID)
            if remaining != entries { try? j.save(remaining) }
            entries = remaining
            attempt += 1
            if entries.isEmpty || attempt > retries { break }
            wait()
        }
    }

    // MARK: Internals

    /// Resumes journaled processes; returns the entries that are still unresolved.
    /// Only identity is checked (pid > 1, not ourselves, our uid, same start time), not the
    /// path-based deny-list: SIGCONT to a process we stopped ourselves is benign, and a
    /// transiently unreadable path must not leave it stopped.
    /// A failed or empty listing means "unknown": nothing is signalled and nothing dropped.
    static func resume(_ entries: [Int32: Double], table: ProcessTable, signaler: Signaler,
                       selfPID: Int32, myUID: uid_t) -> [Int32: Double] {
        guard !entries.isEmpty else { return [:] }
        guard let snap = table.snapshot(), !snap.isEmpty else { return entries }
        let byPID = index(snap)
        var remaining: [Int32: Double] = [:]
        for pid in entries.keys.sorted() {
            let start = entries[pid]!
            guard let c = byPID[pid] else { continue }               // verifiably gone
            guard same(c.startTime, start) else { continue }         // pid reused: not ours
            guard pid > 1, pid != selfPID, c.uid == myUID, c.uid != 0 else {
                remaining[pid] = start; continue                     // cannot signal safely now
            }
            if !signaler.send(SIGCONT, to: pid) { remaining[pid] = start }
        }
        return remaining
    }

    private func protected(_ p: ProcInfo) -> Bool { isProtected(p, selfPID: selfPID, myUID: myUID) }

    /// Targets still alive with the same identity and still not protected.
    private func survivors(_ targets: [ProcInfo]) -> [ProcInfo] {
        let byPID = Self.index(table.list())
        return targets.compactMap { t in
            guard let c = byPID[t.pid], Self.same(c.startTime, t.startTime), !protected(c) else { return nil }
            return c
        }
    }

    /// Roots plus all their descendants (by ppid). Protected processes are neither added nor
    /// traversed, so a rule can never spread through launchd or a system service.
    private func withDescendants(_ roots: [Int32: ProcInfo], in all: [ProcInfo]) -> [Int32: ProcInfo] {
        var children: [Int32: [ProcInfo]] = [:]
        for p in all where p.pid != p.ppid { children[p.ppid, default: []].append(p) }
        var out = roots
        var queue = Array(roots.keys)
        while let pid = queue.popLast() {
            for c in children[pid] ?? [] where out[c.pid] == nil && !protected(c) {
                out[c.pid] = c
                queue.append(c.pid)
            }
        }
        return out
    }

    private static func index(_ procs: [ProcInfo]) -> [Int32: ProcInfo] {
        Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Start times match (journal round-trips through Double seconds; kernel resolution is 1 µs).
    static func same(_ a: Date, _ b: Date) -> Bool { same(a, b.timeIntervalSince1970) }
    static func same(_ a: Date, _ b: Double) -> Bool { abs(a.timeIntervalSince1970 - b) < 0.0005 }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
