import Foundation
@testable import SafeNetCore

private func tmpURL() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("safenet-test-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("config.yaml")
}

private final class Box<T> {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.lock(); defer { lock.unlock() }; return v }
                   set { lock.lock(); v = newValue; lock.unlock() } }
}

func registerConfigTests() {
    test("testDefaultsMatchSpec") {
        let c = Config.default
        expectEqual(c.grace, 20)
        expectEqual(c.closeTimeout, 5)
        expectEqual(c.checkInterval, 5)
        expectEqual(c.minAgree, 2)
        expectEqual(c.onTimeout, .close)
        expectEqual(c.theme, .system)
        expectEqual(c.accent, "blue")
        expectEqual(c.dnsCheck, .warn)
        expectEqual(c.menubar, .ip)
        expect(c.blockWhenOffline)
    }

    test("testPauseDefaultKey") {
        expectEqual(Config.default.pauseDefault, 900, "15 min by default")
        var c = Config.default
        c.pauseDefault = 300
        let store = ConfigStore(url: tmpURL())
        try store.save(c)
        try expectEqual(store.load().pauseDefault, 300)
        try expectEqual(Config(yaml: MiniYAML.parse("pause_default: 1h\n")).pauseDefault, 3600)
        expectThrows({ _ = try Config(yaml: MiniYAML.parse("pause_default: 0\n")) }, "must be > 0")
    }

    test("testRoundTripYAML") {
        var c = Config.default
        c.apps = ["Claude", "Cursor"]
        c.customApps = [CustomApp(name: "My Tool", match: "args:--ai"), CustomApp(name: "X: y", match: "#odd")]
        c.allow = AllowList(ips: ["203.0.113.7"], countries: ["NL", "NO"])
        c.appRules = ["Claude": AllowList(ips: [], countries: ["US"])]
        c.appGrace = ["Cursor": 45.5]
        c.grace = 30
        c.onTimeout = .keepFrozen
        c.dnsCheck = .block
        c.theme = .dark
        c.accent = "green"
        c.menubar = .country
        c.trustedNetworks = [TrustedNetwork(name: "Home", mac: "aa:bb:cc:dd:ee:ff", ip: "192.168.1.1", subnet: "192.168.1.0/24")]
        let url = tmpURL()
        let store = ConfigStore(url: url)
        try store.save(c)
        try expectEqual(store.load(), c)
        // A second save over an existing file stays valid and equal.
        c.checkIPv6 = false
        try store.save(c)
        try expectEqual(store.load(), c)
    }

    test("testSaveDefaultThenLoadEqualsDefault") {
        let store = ConfigStore(url: tmpURL())
        try store.save(.default)
        try expectEqual(store.load(), .default)
    }

    test("testMissingFileLoadsDefaultsWithoutCreatingFile") {
        let url = tmpURL()
        let store = ConfigStore(url: url)
        try expectEqual(store.load(), .default)
        expect(!FileManager.default.fileExists(atPath: url.path))
    }

    test("testPartialFileFillsDefaults") {
        let url = tmpURL()
        try "grace: 1m\napps:\n  - Claude\n".write(to: url, atomically: true, encoding: .utf8)
        let c = try ConfigStore(url: url).load()
        expectEqual(c.grace, 60)
        expectEqual(c.apps, ["Claude"])
        expectEqual(c.minAgree, 2)
    }

    test("testInvalidValuesThrow") {
        let url = tmpURL()
        let store = ConfigStore(url: url)
        for bad in ["accent: 1e30\n", "apps: [1e30]\n", "grace: 1e30s\n", "grace: 1e30\n", "min_agree: 0\n", "grace: soon\n", "theme: neon\n", "apps: 5\n", "on_timeout: explode\n"] {
            try bad.write(to: url, atomically: true, encoding: .utf8)
            expectThrows({ _ = try store.load() }, bad)
        }
    }

    test("testSaveKeepsComments") {
        let url = tmpURL()
        try "# my notes\ngrace: 20s  # trailing\n# check often\ncheck_interval: 5s\n".write(to: url, atomically: true, encoding: .utf8)
        let store = ConfigStore(url: url)
        var c = try store.load()
        c.grace = 40
        try store.save(c)
        let text = try String(contentsOf: url, encoding: .utf8)
        expect(text.contains("# my notes"), text)
        expect(text.contains("# check often"), text)
        try expectEqual(store.load().grace, 40)
    }

    test("testInvalidYAMLThrowsAndKeepsOld") {
        let url = tmpURL()
        let store = ConfigStore(url: url)
        var good = Config.default
        good.grace = 33
        try store.save(good)
        let current = Box<Config>(try store.load())
        let failures = Box<Int>(0)
        let sem = DispatchSemaphore(value: 0)
        let q = DispatchQueue(label: "test.watch")
        store.watch(queue: q) { result in
            switch result {
            case .success(let c): current.value = c
            case .failure: failures.value += 1
            }
            sem.signal()
        }
        try "grace: [unclosed\n  bad: : :\n\t- x".write(to: url, atomically: true, encoding: .utf8)
        expect(sem.wait(timeout: .now() + 2) == .success, "no callback for broken file")
        expectEqual(failures.value, 1)
        expectEqual(current.value.grace, 33)
        store.stopWatching()
    }

    test("testEmptyConfigFileIsAnError") {
        let url = tmpURL()
        let store = ConfigStore(url: url)
        for text in ["", "   \n\t\n", "# only a comment\n"] {
            try text.write(to: url, atomically: true, encoding: .utf8)
            expectThrows({ _ = try store.load() }, "empty/whitespace/comment-only must not load as defaults: \(text.debugDescription)")
        }
    }

    test("testEmptyConfigFileOnHotReloadKeepsOld") {
        let url = tmpURL()
        let store = ConfigStore(url: url)
        var good = Config.default
        good.allow = AllowList(ips: [], countries: ["NL"])
        try store.save(good)
        let current = Box<Config>(try store.load())
        let failures = Box<Int>(0)
        let sem = DispatchSemaphore(value: 0)
        store.watch(queue: DispatchQueue(label: "test.watch.empty")) { result in
            switch result {
            case .success(let c): current.value = c
            case .failure: failures.value += 1
            }
            sem.signal()
        }
        try "  \n".write(to: url, atomically: false, encoding: .utf8)   // editor truncated the file
        expect(sem.wait(timeout: .now() + 2) == .success, "no callback for emptied file")
        expectEqual(failures.value, 1)
        expectEqual(current.value.allow.countries, ["NL"], "allow list must survive an emptied file")
        store.stopWatching()
    }

    test("testWatchFiresOnEdit") {
        let url = tmpURL()
        let store = ConfigStore(url: url)
        try store.save(.default)
        let got = Box<Config?>(nil)
        let sem = DispatchSemaphore(value: 0)
        store.watch(queue: DispatchQueue(label: "test.watch2")) { result in
            if case .success(let c) = result { got.value = c; sem.signal() }
        }
        var edited = Config.default
        edited.minAgree = 3
        let text = MiniYAML.emit(edited.toYAML())
        try text.write(to: url, atomically: false, encoding: .utf8)
        expect(sem.wait(timeout: .now() + 2) == .success, "no callback within 2s")
        expectEqual(got.value?.minAgree, 3)
        store.stopWatching()
    }

    test("testWatchFiresOnAtomicReplace") {
        let url = tmpURL()
        let store = ConfigStore(url: url)
        try store.save(.default)
        let got = Box<Config?>(nil)
        let sem = DispatchSemaphore(value: 0)
        store.watch(queue: DispatchQueue(label: "test.watch3")) { result in
            if case .success(let c) = result { got.value = c; sem.signal() }
        }
        try "grace: 99\n".write(to: url, atomically: true, encoding: .utf8)
        expect(sem.wait(timeout: .now() + 2) == .success, "no callback within 2s")
        expectEqual(got.value?.grace, 99)
        store.stopWatching()
    }

    test("testHugeNumbersNeverTrapOnSave") {
        var c = Config.default
        c.grace = 1e300
        let store = ConfigStore(url: tmpURL())
        try store.save(c)   // must not trap
        expectThrows({ _ = try store.load() })  // and the result is rejected on load
    }

    test("testWatchSurvivesAtomicRenameWithoutPoll") {
        let url = tmpURL()
        let store = ConfigStore(url: url)
        try store.save(.default)
        let graces = Box<[TimeInterval]>([])
        let sem = DispatchSemaphore(value: 0)
        store.watch(queue: DispatchQueue(label: "test.nopoll1"), pollInterval: nil) { result in
            if case .success(let c) = result { graces.value.append(c.grace); sem.signal() }
        }
        try "grace: 11\n".write(to: url, atomically: true, encoding: .utf8)   // new inode
        expect(sem.wait(timeout: .now() + 2) == .success, "atomic replace not seen")
        // In-place write to the NEW inode: only the re-attached file source can see it (dir sees nothing).
        let h = try FileHandle(forWritingTo: url)
        h.truncateFile(atOffset: 0)
        h.write(Data("grace: 12\n".utf8))
        h.closeFile()
        // truncate briefly leaves an empty file (reported as a failure, ignored here)
        // before the "grace: 12" write is seen: wait until 12 arrives, not just for any event.
        let deadline = DispatchTime.now() + 4
        var seen12 = false
        while !seen12, sem.wait(timeout: deadline) == .success {
            seen12 = graces.value.last == 12
        }
        expect(seen12, "in-place write after replace not seen: \(graces.value)")
        store.stopWatching()
    }

    test("testWatchBeforeFileExistsWithoutPoll") {
        let url = tmpURL()
        let store = ConfigStore(url: url)
        let got = Box<TimeInterval>(0)
        let sem = DispatchSemaphore(value: 0)
        store.watch(queue: DispatchQueue(label: "test.nopoll2"), pollInterval: nil) { result in
            if case .success(let c) = result { got.value = c.grace; sem.signal() }
        }
        try "grace: 21\n".write(to: url, atomically: false, encoding: .utf8)
        expect(sem.wait(timeout: .now() + 2) == .success, "first write not seen")
        expectEqual(got.value, 21)
        store.stopWatching()
    }

    test("testNoCallbacksAfterStopWatching") {
        let url = tmpURL()
        let store = ConfigStore(url: url)
        try store.save(.default)
        let calls = Box<Int>(0)
        store.watch(queue: DispatchQueue(label: "test.stop"), pollInterval: 0.1) { _ in calls.value += 1 }
        store.stopWatching()
        try "grace: 77\n".write(to: url, atomically: true, encoding: .utf8)
        Thread.sleep(forTimeInterval: 0.6)
        expectEqual(calls.value, 0)
    }

    test("testQuickWatchStopCycles") {
        let url = tmpURL()
        let store = ConfigStore(url: url)
        try store.save(.default)
        for _ in 0..<50 { store.watch(queue: DispatchQueue(label: "test.cycle"), pollInterval: 0.01) { _ in }; store.stopWatching() }
        expect(true)
    }
}
