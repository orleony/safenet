import Foundation
@testable import SafeNetCore

private func tmpLogURL() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("safenet-evlog-\(UUID().uuidString)", isDirectory: true)
    return dir.appendingPathComponent("sub/events.jsonl")   // parent dir does not exist yet
}

private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent())
}

private func ev(_ kind: EventKind, _ n: Int = 0, app: String? = nil, detail: String = "d") -> Event {
    Event(id: "id\(n)", date: Date(timeIntervalSince1970: 1_700_000_000 + Double(n)), kind: kind, app: app, detail: detail)
}

func registerEventLogTests() {
    test("testAppendAndRecentNewestFirst") {
        let url = tmpLogURL(); defer { cleanup(url) }
        let log = EventLog(url: url)
        log.append(ev(.networkChanged, 1))
        log.append(ev(.ipChanged, 2))
        log.append(ev(.frozen, 3, app: "Claude"))
        let r = log.recent(limit: 10, kinds: nil)
        expectEqual(r.map { $0.id }, ["id3", "id2", "id1"])
        expectEqual(r[0], ev(.frozen, 3, app: "Claude"))
    }

    test("testStatsCountsResumedAndClosed") {
        let url = tmpLogURL(); defer { cleanup(url) }
        let log = EventLog(url: url)
        log.append(ev(.frozen, 1)); log.append(ev(.resumed, 2))
        log.append(ev(.frozen, 3)); log.append(ev(.closed, 4)); log.append(ev(.closed, 5))
        log.append(ev(.resumed, 6)); log.append(ev(.paused, 7)); log.append(ev(.leak, 8))
        expectEqual(log.stats(), Stats(resumedInTime: 2, closed: 2, freezes: 2))
    }

    test("testFilterByKind") {
        let url = tmpLogURL(); defer { cleanup(url) }
        let log = EventLog(url: url)
        log.append(ev(.frozen, 1)); log.append(ev(.closed, 2)); log.append(ev(.resumed, 3)); log.append(ev(.closed, 4))
        expectEqual(log.recent(limit: 10, kinds: [.closed]).map { $0.id }, ["id4", "id2"])
        expectEqual(log.recent(limit: 10, kinds: [.closed, .frozen]).map { $0.id }, ["id4", "id2", "id1"])
        expectEqual(log.recent(limit: 10, kinds: []).count, 0)
    }

    test("testClear") {
        let url = tmpLogURL(); defer { cleanup(url) }
        let log = EventLog(url: url)
        log.append(ev(.frozen, 1)); log.append(ev(.closed, 2)); log.append(ev(.resumed, 3))
        log.clear()
        expectEqual(log.recent(limit: 10, kinds: nil).count, 0)
        expectEqual(log.stats(), Stats(resumedInTime: 0, closed: 0, freezes: 0))
        log.append(ev(.closed, 4))
        expectEqual(log.stats(), Stats(resumedInTime: 0, closed: 1, freezes: 0))
        // also survives reopen
        expectEqual(EventLog(url: url).recent(limit: 10, kinds: nil).map { $0.id }, ["id4"])
    }

    test("testCorruptedLineIsSkipped") {
        let url = tmpLogURL(); defer { cleanup(url) }
        let log = EventLog(url: url)
        log.append(ev(.frozen, 1))
        let h = try FileHandle(forWritingTo: url)
        h.seekToEndOfFile()
        h.write("{garbage not json\n\u{0}\u{1}binary\n{\"kind\":\"nope\"}\n".data(using: .utf8)!)
        h.closeFile()
        log.append(ev(.closed, 2))
        let r = EventLog(url: url).recent(limit: 10, kinds: nil)
        expectEqual(r.map { $0.id }, ["id2", "id1"])
    }

    test("testRecentHonoursLimit") {
        let url = tmpLogURL(); defer { cleanup(url) }
        let log = EventLog(url: url)
        for i in 1...10 { log.append(ev(.networkChanged, i)) }
        expectEqual(log.recent(limit: 3, kinds: nil).map { $0.id }, ["id10", "id9", "id8"])
        expectEqual(log.recent(limit: 0, kinds: nil).count, 0)
        expectEqual(log.recent(limit: 100, kinds: nil).count, 10)
    }

    test("testReopenSeesPriorDataAndStats") {
        let url = tmpLogURL(); defer { cleanup(url) }
        let a = EventLog(url: url)
        a.append(ev(.frozen, 1)); a.append(ev(.resumed, 2)); a.append(ev(.closed, 3))
        let b = EventLog(url: url)
        expectEqual(b.recent(limit: 10, kinds: nil).count, 3)
        expectEqual(b.stats(), Stats(resumedInTime: 1, closed: 1, freezes: 1))
    }

    test("testStatsRecomputedWhenSidecarMissing") {
        let url = tmpLogURL(); defer { cleanup(url) }
        let a = EventLog(url: url)
        a.append(ev(.frozen, 1)); a.append(ev(.resumed, 2))
        try FileManager.default.removeItem(atPath: url.path + ".stats.json")
        expectEqual(EventLog(url: url).stats(), Stats(resumedInTime: 1, closed: 0, freezes: 1))
    }

    test("testRotationKeepsNewestAndPreservesStats") {
        let url = tmpLogURL(); defer { cleanup(url) }
        let log = EventLog(url: url)
        let big = String(repeating: "x", count: 1000)
        let n = 3000   // ~3.3 MB > 2 MB limit
        for i in 1...n {
            log.append(ev(i % 2 == 0 ? .closed : .frozen, i, detail: big))
        }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        expect(size <= 2 * 1024 * 1024, "file size \(size) exceeds limit")
        let r = log.recent(limit: 100_000, kinds: nil)
        expect(r.count < n && r.count > 500, "retained \(r.count)")
        expectEqual(r.first?.id, "id\(n)")
        // retained events are a contiguous newest run
        for (k, e) in r.enumerated() { expectEqual(e.id, "id\(n - k)") }
        // cumulative stats not lost
        expectEqual(log.stats(), Stats(resumedInTime: 0, closed: n / 2, freezes: n / 2))
        expectEqual(EventLog(url: url).stats(), Stats(resumedInTime: 0, closed: n / 2, freezes: n / 2))
    }

    test("testConcurrentAppendsNoLostOrGarbledLines") {
        let url = tmpLogURL(); defer { cleanup(url) }
        let log = EventLog(url: url)
        let threads = 8, per = 100
        let group = DispatchGroup()
        for t in 0..<threads {
            group.enter()
            Thread.detachNewThread {
                for i in 0..<per { log.append(ev(.closed, t * 1000 + i, app: "T\(t)")) }
                group.leave()
            }
        }
        group.wait()
        let r = log.recent(limit: 100_000, kinds: nil)
        expectEqual(r.count, threads * per)
        expectEqual(Set(r.map { $0.id }).count, threads * per)
        expectEqual(log.stats().closed, threads * per)
        let raw = try String(contentsOf: url, encoding: .utf8)
        expectEqual(raw.split(separator: "\n").count, threads * per)
    }

    test("testEventStoresOnlyGivenFields") {
        let url = tmpLogURL(); defer { cleanup(url) }
        let log = EventLog(url: url)
        log.append(ev(.closed, 1, app: "Claude", detail: "timeout"))
        let raw = try String(contentsOf: url, encoding: .utf8)
        let obj = try JSONSerialization.jsonObject(with: raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8)!) as! [String: Any]
        expectEqual(Set(obj.keys), Set(["id", "date", "kind", "app", "detail"]))
        expectEqual(obj["kind"] as? String, "closed")
        expect((obj["date"] as? String)?.hasSuffix("Z") == true, "ISO8601 date")
        let e = Event(kind: .paused, app: nil, detail: "x")
        expectEqual(e.id.count, 36)
        expect(abs(e.date.timeIntervalSinceNow) < 5)
    }

    test("testAppendFailureDoesNotCrashAndRecovers") {
        let url = tmpLogURL(); defer { cleanup(url) }
        // Make the log path a directory: opening it for writing must fail, not trap.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let log = EventLog(url: url)
        log.append(ev(.closed, 1))
        expectEqual(log.stats(), Stats(resumedInTime: 0, closed: 0, freezes: 0), "failed write must not count")
        expectEqual(log.recent(limit: 10, kinds: nil).count, 0)
        try FileManager.default.removeItem(at: url)
        log.append(ev(.closed, 2))
        expectEqual(log.recent(limit: 10, kinds: nil).map { $0.id }, ["id2"])
        expectEqual(log.stats().closed, 1)
    }
}
