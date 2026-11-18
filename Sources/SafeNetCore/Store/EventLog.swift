import Foundation

public enum EventKind: String, Codable, CaseIterable {
    case networkChanged, ipChanged, frozen, resumed, closed, paused, leak
}

/// One history entry. Holds only the fields below (no personal data is added by the log).
public struct Event: Codable, Equatable {
    public var id: String
    public var date: Date
    public var kind: EventKind
    public var app: String?
    public var detail: String

    public init(id: String = UUID().uuidString, date: Date = Date(), kind: EventKind,
                app: String? = nil, detail: String) {
        self.id = id; self.date = date; self.kind = kind; self.app = app; self.detail = detail
    }
}

public struct Stats: Equatable, Codable {
    /// Number of `resumed` events: the VPN/IP came back before the timeout.
    public var resumedInTime: Int
    /// Number of `closed` events: apps that were closed.
    public var closed: Int
    /// Number of `frozen` events.
    public var freezes: Int

    public init(resumedInTime: Int = 0, closed: Int = 0, freezes: Int = 0) {
        self.resumedInTime = resumedInTime; self.closed = closed; self.freezes = freezes
    }
}

/// Append-only JSONL event history (one JSON object per line, ISO8601 dates, second precision).
///
/// Stats are CUMULATIVE counters persisted in a sidecar `<file>.stats.json` (written atomically),
/// so rotation never loses totals. If the sidecar is missing or unreadable, counters are
/// recomputed once from the events still in the file. `clear()` resets both file and counters.
/// When the file grows beyond `maxBytes` (2 MB) the oldest half of the lines is dropped.
/// Corrupted lines are skipped on read. All operations are serialized with a lock.
public final class EventLog {
    public static let maxBytes = 2 * 1024 * 1024

    private let url: URL
    private let statsURL: URL
    private let lock = NSLock()
    private let maxBytes: Int
    private var counters: Stats?   // lazily loaded

    public init(url: URL) {
        self.url = url
        self.statsURL = URL(fileURLWithPath: url.path + ".stats.json")
        self.maxBytes = EventLog.maxBytes
    }

    /// Cheap change detector for readers (size + modification time of the log and its stats
    /// file): equal stamps mean nothing to reload.
    public func changeStamp() -> String {
        func part(_ u: URL) -> String {
            var st = stat()
            guard stat(u.path, &st) == 0 else { return "-" }
            return "\(st.st_size).\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
        }
        return part(url) + "|" + part(statsURL)
    }

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }
    private func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    private func ensureDir() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    // MARK: file reading (lock held)

    private func readLines() -> [Data] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
    }

    private func decodeAll(_ lines: [Data]) -> [Event] {
        let d = decoder()
        return lines.compactMap { try? d.decode(Event.self, from: $0) }
    }

    // MARK: counters (lock held)

    private func apply(_ e: Event, to s: inout Stats) {
        switch e.kind {
        case .resumed: s.resumedInTime += 1
        case .closed: s.closed += 1
        case .frozen: s.freezes += 1
        default: break
        }
    }

    private func loadCounters() -> Stats {
        if let c = counters { return c }
        var s: Stats
        if let data = try? Data(contentsOf: statsURL), let loaded = try? JSONDecoder().decode(Stats.self, from: data) {
            s = loaded
        } else {
            s = Stats()
            for e in decodeAll(readLines()) { apply(e, to: &s) }
            persist(s)
        }
        counters = s
        return s
    }

    private func persist(_ s: Stats) {
        ensureDir()
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: statsURL, options: .atomic) }
    }

    // MARK: API

    /// Appends one event. I/O failures (full disk, unwritable path, EIO) are swallowed on purpose:
    /// history must never crash the app. Counters are updated (in memory and sidecar) only after the
    /// line was actually written, so stats never count an event that is not in the file.
    public func append(_ e: Event) {
        guard var line = try? encoder().encode(e) else { return }
        line.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        var s = loadCounters()
        ensureDir()
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return }
        }
        var newSize: UInt64 = 0
        do {
            let h = try FileHandle(forUpdating: url)
            defer { try? h.close() }
            let size = try h.seekToEnd()
            // Ensure a previous unterminated/corrupted tail cannot glue onto this record.
            if size > 0 {
                try h.seek(toOffset: size - 1)
                let last = try h.read(upToCount: 1)
                try h.seekToEnd()
                if last != Data([0x0A]) { try h.write(contentsOf: Data([0x0A])) }
            }
            try h.write(contentsOf: line)
            newSize = try h.offset()
        } catch {
            return
        }
        apply(e, to: &s)
        counters = s
        persist(s)
        if Int(newSize) > maxBytes { rotate() }
    }

    /// Keeps the newest half of the lines (by count). Lock held.
    private func rotate() {
        let lines = readLines()
        guard lines.count > 1 else { return }
        let kept = lines[(lines.count / 2)...]
        var out = Data()
        for l in kept { out.append(l); out.append(0x0A) }
        try? out.write(to: url, options: .atomic)
    }

    /// Newest first. `kinds == nil` means all kinds.
    public func recent(limit: Int, kinds: Set<EventKind>? = nil) -> [Event] {
        guard limit > 0 else { return [] }
        lock.lock(); defer { lock.unlock() }
        var out: [Event] = []
        let d = decoder()
        for line in readLines().reversed() {
            guard let e = try? d.decode(Event.self, from: line) else { continue }
            if let k = kinds, !k.contains(e.kind) { continue }
            out.append(e)
            if out.count >= limit { break }
        }
        return out
    }

    public func stats() -> Stats {
        lock.lock(); defer { lock.unlock() }
        return loadCounters()
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
        counters = Stats()
        persist(Stats())
    }
}
