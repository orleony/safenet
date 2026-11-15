import Foundation

public protocol Cancellable: AnyObject {
    func cancel()
}

/// Time source for the Guard. `now` is wall-clock time (for display and deadlines);
/// `schedule` runs `f` once after `after` seconds unless cancelled.
public protocol Clock: AnyObject {
    var now: Date { get }
    func schedule(after: TimeInterval, _ f: @escaping () -> Void) -> Cancellable
}

/// Real clock. Timers use `DispatchTime` (mach absolute time): monotonic, unaffected by wall-clock
/// changes, and not advancing while the Mac sleeps, so a countdown can never expire "during" sleep.
public final class SystemClock: Clock {
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = DispatchQueue(label: "safenet.clock")) { self.queue = queue }

    public var now: Date { Date() }

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

/// Deterministic clock for tests: time moves only through `advance(by:)`, which fires due timers
/// in order of due time (ties: scheduling order), setting `now` to each timer's due time first.
/// Timers scheduled while firing are honoured within the same advance if due.
public final class FakeClock: Clock {
    private let lock = NSLock()
    private var _now: Date
    private var seq = 0
    private var timers: [Timer] = []

    private final class Timer: Cancellable {
        let due: Date; let seq: Int; let f: () -> Void
        private let lock = NSLock()
        private var _cancelled = false
        init(_ due: Date, _ seq: Int, _ f: @escaping () -> Void) { self.due = due; self.seq = seq; self.f = f }
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
        func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    }

    public init(start: Date = Date(timeIntervalSince1970: 0)) { _now = start }

    public var now: Date { lock.lock(); defer { lock.unlock() }; return _now }

    /// Number of scheduled, not cancelled, not yet fired timers.
    public var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return timers.filter { !$0.cancelled }.count }

    public func schedule(after: TimeInterval, _ f: @escaping () -> Void) -> Cancellable {
        lock.lock(); defer { lock.unlock() }
        seq += 1
        let t = Timer(_now.addingTimeInterval(after.isFinite ? max(0, after) : 1e12), seq, f)
        timers.append(t)
        return t
    }

    public func advance(by dt: TimeInterval) {
        lock.lock()
        let target = _now.addingTimeInterval(max(0, dt))
        lock.unlock()
        while true {
            lock.lock()
            timers.removeAll { $0.cancelled }
            guard let next = timers.filter({ $0.due <= target })
                    .min(by: { ($0.due, $0.seq) < ($1.due, $1.seq) }) else {
                _now = target
                lock.unlock()
                return
            }
            timers.removeAll { $0 === next }
            if next.due > _now { _now = next.due }
            lock.unlock()
            next.f()
        }
    }
}
