import Foundation
import Darwin

/// `<support dir>/safenet.lock`: one owner of the freeze journal at a time. The running app holds
/// it for its whole life (a second instance must not reconcile / quit-resume the first one's
/// frozen apps); after the app died, its watchdog takes it while it retries resuming, so a
/// relaunched app waits for it instead of having its fresh freezes resumed and its journal
/// overwritten. `flock` on a descriptor opened `O_CLOEXEC` (a spawned child never inherits it);
/// the kernel releases it when the holder exits, also on a crash or `kill -9`.
public final class InstanceLock {
    /// `acquired`: we own it. `busy`: another live process holds it. `unavailable`: the file cannot
    /// be opened/locked at all (unwritable or broken support dir): nobody can hold it, so callers
    /// must not treat it as "another instance runs" (see `LiveSystem` / the watchdog).
    public enum Outcome: Equatable { case acquired, busy, unavailable(Int32) }

    /// The watchdog holds the lock for at most ~11 s (1 s to take it + 20 retries 0.5 s apart).
    public static let watchdogHold: TimeInterval = 11
    /// A starting app waits this long for it (comfortably longer than `watchdogHold`).
    public static let appWait: TimeInterval = 20

    public let url: URL
    private var fd: Int32 = -1
    private let mutex = NSLock()

    public init(url: URL) { self.url = url }
    deinit { release() }

    /// The lock next to a journal (same directory, so `SAFENET_CONFIG_DIR` is honoured).
    public static func path(forJournal journal: URL) -> URL {
        journal.deletingLastPathComponent().appendingPathComponent("safenet.lock")
    }

    public var isHeld: Bool { mutex.lock(); defer { mutex.unlock() }; return fd >= 0 }

    /// One non-blocking attempt.
    public func tryAcquire() -> Bool { attempt() == .acquired }

    public func attempt() -> Outcome {
        mutex.lock(); defer { mutex.unlock() }
        if fd >= 0 { return .acquired }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let f = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard f >= 0 else { return .unavailable(errno) }
        if flock(f, LOCK_EX | LOCK_NB) != 0 {
            let e = errno
            close(f)
            return e == EWOULDBLOCK ? .busy : .unavailable(e)
        }
        fd = f
        return .acquired
    }

    /// Retries every `poll` seconds while BUSY until `timeout` has been waited; `unavailable`
    /// returns at once (waiting cannot fix it).
    public func acquire(timeout: TimeInterval, poll: TimeInterval = 0.2,
                        sleep: (TimeInterval) -> Void = { usleep(useconds_t(max(0, $0) * 1_000_000)) }) -> Outcome {
        var r = attempt()
        var waited = 0.0
        while r == .busy && waited < timeout {
            let step = max(0.01, min(poll, timeout - waited))
            sleep(step); waited += step
            r = attempt()
        }
        return r
    }

    public func release() {
        mutex.lock(); defer { mutex.unlock() }
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN); close(fd); fd = -1
    }

    /// For tests: the descriptor has FD_CLOEXEC.
    var descriptorIsCloseOnExec: Bool {
        mutex.lock(); defer { mutex.unlock() }
        return fd >= 0 && (fcntl(fd, F_GETFD) & FD_CLOEXEC) != 0
    }
}
