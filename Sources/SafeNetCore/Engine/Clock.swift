import Foundation

public protocol Cancellable: AnyObject {
    func cancel()
}

/// Time source for the Guard.
/// - `now`: wall-clock time, for display only (it can jump: NTP, manual change).
/// - `uptime`: monotonic seconds that do not advance while the Mac sleeps; all countdowns use it.
/// - `schedule`: runs `f` once after `after` seconds of `uptime` unless cancelled.
public protocol Clock: AnyObject {
    var now: Date { get }
    var uptime: TimeInterval { get }
    func schedule(after: TimeInterval, _ f: @escaping () -> Void) -> Cancellable
}

/// Real clock. `uptime` = `ProcessInfo.systemUptime` (mach absolute time) and timers use
/// `DispatchTime` (same base): monotonic, unaffected by wall-clock changes, paused during sleep.
public final class SystemClock: Clock {
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = DispatchQueue(label: "safenet.clock")) { self.queue = queue }

    public var now: Date { Date() }
    public var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private final class Item: Cancellable {
        let work: DispatchWorkItem
        init(_ w: DispatchWorkItem) { work = w }
        func cancel() { work.cancel() }
    }

    public func schedule(after: TimeInterval, _ f: @escaping () -> Void) -> Cancellable {
        let w = DispatchWorkItem(block: f)
        let delay = after.isFinite ? max(0, min(after, 365 * 86_400)) : 365 * 86_400
        queue.asyncAfter(deadline: .now() + delay, execute: w)
        return Item(w)
    }
}

/// Deterministic clock for tests. `advance(by:)` moves uptime and wall time together and fires
/// due timers in order of due time (ties: scheduling order), setting the time to each timer's due
/// time first; timers scheduled while firing are honoured within the same advance if due.
/// `jumpWallClock(by:)` shifts only the wall clock (NTP step / manual change).
public final class FakeClock: Clock {
    private let lock = NSLock()
    private let start: Date
    private var _uptime: TimeInterval = 0
    private var wallOffset: TimeInterval = 0
    private var seq = 0
    private var timers: [Timer] = []

    private final class Timer: Cancellable {
        let due: TimeInterval; let seq: Int; let f: () -> Void
        private let lock = NSLock()
        private var _cancelled = false
        init(_ due: TimeInterval, _ seq: Int, _ f: @escaping () -> Void) { self.due = due; self.seq = seq; self.f = f }
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
        func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    }

    public init(start: Date = Date(timeIntervalSince1970: 0)) { self.start = start }

    public var now: Date { lock.lock(); defer { lock.unlock() }; return start.addingTimeInterval(_uptime + wallOffset) }
    public var uptime: TimeInterval { lock.lock(); defer { lock.unlock() }; return _uptime }

    /// Number of scheduled, not cancelled, not yet fired timers.
    public var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return timers.filter { !$0.cancelled }.count }

    public func jumpWallClock(by dt: TimeInterval) { lock.lock(); wallOffset += dt; lock.unlock() }

    public func schedule(after: TimeInterval, _ f: @escaping () -> Void) -> Cancellable {
        lock.lock(); defer { lock.unlock() }
        seq += 1
        let t = Timer(_uptime + (after.isFinite ? max(0, after) : 1e12), seq, f)
        timers.append(t)
        return t
    }

    public func advance(by dt: TimeInterval) {
        lock.lock()
        let target = _uptime + max(0, dt)
        lock.unlock()
        while true {
            lock.lock()
            timers.removeAll { $0.cancelled }
            guard let next = timers.filter({ $0.due <= target })
                    .min(by: { ($0.due, $0.seq) < ($1.due, $1.seq) }) else {
                _uptime = target
                lock.unlock()
                return
            }
            timers.removeAll { $0 === next }
            if next.due > _uptime { _uptime = next.due }
            lock.unlock()
            next.f()
        }
    }
}
