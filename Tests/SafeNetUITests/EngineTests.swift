import Foundation
import Darwin
import SafeNetCore
@testable import SafeNetUI

// Engine tests: FakeClock, fake process table and signaler (never signal a real process),
// synchronous fake IP / route fetchers.

private let me = getuid()

private func eproc(_ pid: Int32, _ app: String) -> ProcInfo {
    let path = "/Applications/\(app).app/Contents/MacOS/\(app)"
    return ProcInfo(pid: pid, ppid: 1, name: app, path: path, args: path,
                    startTime: Date(timeIntervalSince1970: 1000), uid: me)
}

private final class ETable: ProcessTable {
    var procs: [ProcInfo]
    init(_ p: [ProcInfo]) { procs = p }
    func list() -> [ProcInfo] { procs }
    func snapshot() -> [ProcInfo]? { procs }
}

private final class ESignaler: Signaler {
    var sent: [(Int32, Int32)] = []
    func send(_ sig: Int32, to pid: Int32) -> Bool { sent.append((sig, pid)); return true }
    func pids(_ sig: Int32) -> [Int32] { sent.filter { $0.0 == sig }.map { $0.1 } }
}

private let online = NetSnapshot(online: true, hasTunnel: true, gatewayIP: nil, gatewayMAC: nil, proxy: nil)
private func a(_ ip: String, _ cc: String) -> IPAnswer { IPAnswer(ip: ip, country: cc) }

private final class ERig {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("safenet-engine-\(UUID().uuidString)")
    let clock = FakeClock(start: Date(timeIntervalSince1970: 1_800_000_000))
    let table = ETable([eproc(100, "Telegram")])
    let sig = ESignaler()
    let store: ConfigStore
    let freezer: Freezer
    var answers: [IPAnswer] = [a("5.6.7.8", "RU"), a("5.6.7.8", "RU")]
    var routeResults: [RouteResult] = []
    var routeCalls = 0
    var fetchCalls = 0
    /// Mode of every fetch, in order.
    var modes: [IPFetchMode] = []
    /// Answers of the cheap services (nil = the same as `answers`).
    var cheapAnswers: [IPAnswer]?
    /// When set, the next fetch is held until `release()`.
    var holdFetch = false
    var held: (() -> Void)?
    var engine: Engine!
    var errors: [String] = []

    var notices: [String] = []
    /// Test mode without SAFENET_CONFIG_DIR: disk writes refused with this message.
    var writesBlocked: String?

    init(config: Config?, writesBlocked: String? = nil) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = ConfigStore(url: dir.appendingPathComponent("config.yaml"))
        if let c = config { try! store.save(c) }
        freezer = Freezer(table: table, signaler: sig, journal: dir.appendingPathComponent("frozen.json"),
                          selfPID: 7, myUID: me, pollInterval: 0.01)
        self.writesBlocked = writesBlocked
        rebuild()
    }

    var lastGood: URL { dir.appendingPathComponent("config.last-good.yaml") }

    /// (Re)creates the engine on the same directory (simulates a relaunch).
    func rebuild() {
        var deps = EngineDeps(
            clock: clock, freezer: freezer, log: EventLog(url: dir.appendingPathComponent("events.jsonl")), store: store,
            fetchAnswers: { [unowned self] mode, cb in
                self.fetchCalls += 1
                self.modes.append(mode)
                let now = mode == .cheap ? (self.cheapAnswers ?? self.answers) : self.answers
                if self.holdFetch { self.held = { cb(now) } } else { cb(now) }
            },
            probeRoutes: { [unowned self] _, cb in self.routeCalls += 1; cb(self.routeResults) },
            resolvers: { [DNSResolver(address: "10.8.0.1", interface: "utun3", scoped: false)] },
            snapshotNow: { online }, queue: nil)
        deps.tickInterval = 1
        deps.configWritesBlocked = writesBlocked
        engine = Engine(deps: deps)
        engine.onConfigError = { [unowned self] in self.errors.append($0) }
        engine.onNotice = { [unowned self] in self.notices.append($0) }
    }
    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }
    /// Delivers the held fetch; later fetches stay held while `holdFetch` is true.
    func release() { let cb = held; held = nil; cb?() }
}

private func cfg(apps: [String] = ["telegram"], countries: [String] = ["NL"]) -> Config {
    var c = Config.default
    c.apps = apps
    c.allow = AllowList(ips: [], countries: countries)
    c.closeTimeout = 0
    return c
}

/// Tiered-polling tests: route check off so only the IP checks are counted.
private func tiered(apps: [String] = ["telegram"]) -> Config {
    var c = cfg(apps: apps, countries: ["RU"]); c.routeCheck = false; return c
}

func registerEngineTests() {
    test("testEngineFirstBadObservationFreezes") {
        let r = ERig(config: cfg())
        r.engine.start(watchConfig: false)
        r.engine.networkChanged(online)
        expectEqual(r.engine.guardian.frozenApps, ["telegram"])
        expect(r.sig.pids(SIGSTOP).contains(100), "telegram must be stopped")
        if case .frozen(_, let reason, _) = r.engine.status.state { expectEqual(reason, .countryNotAllowed) }
        else { expect(false, "not frozen: \(r.engine.status.state)") }
        expectEqual(r.engine.status.confirmed, a("5.6.7.8", "RU"))
    }

    test("testEngineGoodObservationResumes") {
        let r = ERig(config: cfg(countries: ["RU"]))
        r.engine.start(watchConfig: false)
        r.engine.networkChanged(online)
        expectEqual(r.engine.status.state, .ok)
        expectEqual(r.freezer.frozenPIDs, [])
    }

    test("testEngineMissingConfigWritesDefaults") {
        let r = ERig(config: nil)
        expect(FileManager.default.fileExists(atPath: r.store.url.path), "defaults must be written on first run")
        try expectEqual(r.store.load(), Config.default)
    }

    test("testFirstRunPromptState") {
        expect(Engine.needsAllowSetup(cfg(countries: [])), "apps selected, empty allow list")
        expect(!Engine.needsAllowSetup(cfg(apps: [], countries: [])), "no apps: no prompt")
        expect(!Engine.needsAllowSetup(cfg(countries: ["NL"])))
        var c = cfg(countries: [])
        c.appRules = ["telegram": AllowList(ips: ["1.2.3.4"], countries: [])]
        expect(!Engine.needsAllowSetup(c), "per-app rule covers the only app")
        c.apps = ["telegram", "chatgpt"]
        expect(Engine.needsAllowSetup(c), "chatgpt has no allow list")
        expect(!Engine.needsAllowSetup(cfg(apps: ["safari"], countries: [])), "unsupported id is not protected")
    }

    test("testAllowCurrentCountryAddsConfirmedCountryAndSaves") {
        let r = ERig(config: cfg(countries: []))
        r.engine.start(watchConfig: false)
        r.engine.networkChanged(online)
        expect(r.engine.allowCurrentCountry())
        expectEqual(r.engine.config.allow.countries, ["RU"])
        try expectEqual(r.store.load().allow.countries, ["RU"])
        expectEqual(r.engine.status.state, .ok, "apps resume at once")
    }

    test("testAllowCurrentCountryNeedsConfirmedIP") {
        let r = ERig(config: cfg(countries: []))
        r.answers = [a("5.6.7.8", "RU"), a("9.9.9.9", "DE")]
        r.engine.start(watchConfig: false)
        r.engine.networkChanged(online)
        expect(!r.engine.allowCurrentCountry())
        expectEqual(r.engine.config.allow.countries, [])
    }

    test("testOnAllowIPAppendsToConfig") {
        let r = ERig(config: cfg())
        r.engine.start(watchConfig: false)
        r.engine.networkChanged(online)
        r.engine.guardian.allowCurrentIP()
        expectEqual(r.engine.config.allow.ips, ["5.6.7.8"])
        try expectEqual(r.store.load().allow.ips, ["5.6.7.8"])
        expectEqual(r.engine.status.state, .ok)
    }

    test("testEmptyConfigFileHotReloadKeepsOldConfig") {
        let r = ERig(config: cfg())
        let sem = DispatchSemaphore(value: 0)
        r.engine.onConfigError = { _ in sem.signal() }
        r.engine.start(watchConfig: true)
        try "".write(to: r.store.url, atomically: false, encoding: .utf8)
        expect(sem.wait(timeout: .now() + 3) == .success, "no config error reported")
        expectEqual(r.engine.config.allow.countries, ["NL"], "old allow list kept")
        expectEqual(r.engine.config.apps, ["telegram"])
        r.engine.shutdown(deadline: 0)
    }

    test("testRouteProbesNotScheduledWithoutProtectedApps") {
        let r = ERig(config: cfg(apps: []))
        r.engine.start(watchConfig: false)
        r.engine.networkChanged(online)
        r.clock.advance(by: 300)
        expectEqual(r.routeCalls, 0)
        expect(!r.engine.status.routesChecked)
    }

    test("testRouteProbesScheduledWithProtectedApps") {
        let r = ERig(config: cfg(countries: ["RU"]))
        r.routeResults = [RouteResult(host: "claude.ai", ip: "5.6.7.8", country: "RU", error: nil)]
        r.engine.start(watchConfig: false)
        r.clock.advance(by: 0.1)
        expectEqual(r.routeCalls, 1, "first probe at start")
        expect(r.engine.status.routesChecked)
        r.clock.advance(by: 120)
        expectEqual(r.routeCalls, 2, "every 120 s")
        r.engine.networkChanged(online)
        r.clock.advance(by: 0.1)
        expectEqual(r.routeCalls, 3, "after a network change")
    }

    test("testRoutesNilUntilFirstProbe") {
        var c = cfg(countries: ["RU"])
        c.routeCheck = true
        let r = ERig(config: c)
        r.routeResults = []          // would be a route leak (nothing confirmed) once evaluated
        r.engine.start(watchConfig: false)
        // start() checked before the first probe ran: routes nil -> no route leak
        expectEqual(r.engine.status.observation?.routeLeak, false)
        r.clock.advance(by: 0.1)     // probe finished with zero results -> leak
        expectEqual(r.engine.status.observation?.routeLeak, true)
    }

    test("testStaleAnswersDiscardedAfterNetworkChange") {
        let r = ERig(config: cfg(countries: ["NL"]))
        r.answers = [a("1.2.3.4", "NL"), a("1.2.3.4", "NL")]
        r.engine.start(watchConfig: false)
        expectEqual(r.engine.status.state, .ok)
        r.holdFetch = true
        r.engine.checkNow()                      // in flight with the old network
        r.engine.networkChanged(online)          // VPN dropped meanwhile
        r.answers = [a("5.6.7.8", "RU"), a("5.6.7.8", "RU")]
        r.release()                              // stale (old, good) result arrives: must not count
        expectEqual(r.engine.guardian.frozenApps, ["telegram"], "stale good answers must not unfreeze")
        expect(r.held != nil, "a fresh check must be in flight")
        r.holdFetch = false
        r.release()
        expectEqual(r.engine.guardian.frozenApps, ["telegram"])
        if case .frozen(_, let reason, _) = r.engine.status.state { expectEqual(reason, .countryNotAllowed) }
        else { expect(false, "expected frozen, got \(r.engine.status.state)") }
    }

    test("testIPv6AnswerDoesNotBreakQuorum") {
        var c = cfg(countries: ["NL"])
        c.minAgree = 1
        let r = ERig(config: c)
        r.answers = [a("1.2.3.4", "NL"), a("2a01:4f9::1", "NL")]
        r.engine.start(watchConfig: false)
        expectEqual(r.engine.status.state, .ok)
        r.answers = [a("1.2.3.4", "NL"), a("2a01:4f9::1", "DE")]
        r.engine.checkNow()
        if case .frozen(_, let reason, _) = r.engine.status.state { expectEqual(reason, .ipv6Leak) }
        else { expect(false, "expected ipv6 leak, got \(r.engine.status.state)") }
    }

    test("testPollRunsEveryCheckInterval") {
        let r = ERig(config: cfg(countries: ["RU"]))
        r.engine.start(watchConfig: false)
        r.clock.advance(by: 0.1)                 // first route probe (also triggers a check)
        let n = r.fetchCalls
        r.clock.advance(by: 5)
        expectEqual(r.fetchCalls, n + 1)
    }

    test("testShutdownResumesFrozenApps") {
        let r = ERig(config: cfg())
        r.engine.start(watchConfig: false)
        expectEqual(r.freezer.frozenPIDs, [100])
        let left = r.engine.shutdown(deadline: 0)
        expectEqual(left, [])
        expectEqual(r.freezer.frozenPIDs, [])
        expect(r.sig.pids(SIGCONT).contains(100))
        r.clock.advance(by: 100)
        expectEqual(r.sig.pids(SIGTERM), [], "nothing closed after shutdown")
    }

    test("testWakeFreezesAndRechecks") {
        let r = ERig(config: cfg(countries: ["RU"]))
        r.engine.start(watchConfig: false)
        expectEqual(r.engine.status.state, .ok)
        r.engine.willSleep()
        let n = r.fetchCalls
        r.engine.didWake()
        expect(r.fetchCalls > n, "fresh check on wake")
        expectEqual(r.engine.status.state, .ok)
    }

    test("testLeakAllowIsUnionOfEffectiveLists") {
        var c = cfg(apps: ["telegram", "chatgpt"], countries: ["NL"])
        c.appRules = ["chatgpt": AllowList(ips: ["1.1.1.1"], countries: ["US"])]
        let u = Engine.leakAllow(c)
        expectEqual(Set(u.countries), ["NL", "US"])
        expectEqual(u.ips, ["1.1.1.1"])
    }

    // MARK: Fix round 1

    test("testFirstSaveOverBrokenFileKeepsBrokenCopy") {
        let r = ERig(config: cfg())
        let broken = "apps: [telegram\n  bad: : :\n"
        try broken.write(to: r.store.url, atomically: true, encoding: .utf8)
        r.rebuild()
        r.engine.start(watchConfig: false)
        r.engine.toggleApp("chatgpt")                 // first save from the UI
        let copies = try FileManager.default.contentsOfDirectory(atPath: r.dir.path).filter { $0.hasPrefix("config.broken-") && $0.hasSuffix(".yaml") }
        expectEqual(copies.count, 1, "one backup of the broken file: \(copies)")
        if let f = copies.first {
            try expectEqual(String(contentsOf: r.dir.appendingPathComponent(f), encoding: .utf8), broken)
        }
        expect(r.notices.contains { $0.contains("config.broken-") }, "user told about the copy: \(r.notices)")
        expect(!r.notices.contains { $0.contains(r.dir.path) }, "no paths in the notice")
        try expectEqual(r.store.load().apps, ["telegram", "chatgpt"], "file now valid")
        r.engine.toggleApp("chatgpt")                 // later saves: no new copies
        let again = try FileManager.default.contentsOfDirectory(atPath: r.dir.path).filter { $0.hasPrefix("config.broken-") }
        expectEqual(again.count, 1)
    }

    test("testSaveOverValidFileMakesNoBrokenCopy") {
        let r = ERig(config: cfg())
        r.engine.start(watchConfig: false)
        r.engine.toggleApp("chatgpt")
        let copies = try FileManager.default.contentsOfDirectory(atPath: r.dir.path).filter { $0.hasPrefix("config.broken-") }
        expectEqual(copies, [])
    }

    test("testStatusReportsClosedAppsOnly") {
        var c = cfg(apps: ["telegram", "chatgpt"])
        c.appRules = ["chatgpt": AllowList(ips: [], countries: ["RU"])]
        let r = ERig(config: c)
        r.engine.start(watchConfig: false)
        r.engine.networkChanged(online)
        r.table.procs = []                            // the app quit after SIGTERM (fake table keeps it otherwise)
        r.engine.guardian.closeNow()
        expectEqual(r.engine.guardian.closedApps, ["telegram"], "\(r.engine.status.state)")
        expectEqual(r.engine.status.closedApps, ["telegram"])
    }

    test("testBrokenConfigAtLaunchUsesLastGood") {
        let r = ERig(config: cfg())                  // successful load at init writes last-good
        expect(FileManager.default.fileExists(atPath: r.lastGood.path), "last-good written after a successful load")
        let broken = "apps: [telegram\n  bad: : :\n"
        try broken.write(to: r.store.url, atomically: true, encoding: .utf8)
        r.rebuild()
        r.engine.start(watchConfig: false)
        expectEqual(r.engine.config.apps, ["telegram"], "previous settings in use")
        expectEqual(r.engine.config.allow.countries, ["NL"])
        expectEqual(r.errors.count, 1, "error flagged: \(r.errors)")
        expect(r.errors.first?.contains("прежние") == true, "\(r.errors)")
        try expectEqual(String(contentsOf: r.store.url, encoding: .utf8), broken, "broken file left for the user")
        expectEqual(r.engine.guardian.frozenApps, ["telegram"], "protected again (RU not allowed)")
    }

    test("testEmptyConfigAtLaunchUsesLastGood") {
        let r = ERig(config: cfg())
        try "".write(to: r.store.url, atomically: true, encoding: .utf8)
        r.rebuild()
        r.engine.start(watchConfig: false)
        expectEqual(r.engine.config.apps, ["telegram"])
        expectEqual(r.errors.count, 1)
        try expectEqual(String(contentsOf: r.store.url, encoding: .utf8), "")
    }

    test("testBrokenConfigWithoutLastGoodUsesDefaultsWithError") {
        let r = ERig(config: nil)
        try? FileManager.default.removeItem(at: r.lastGood)
        try "grace: [\n".write(to: r.store.url, atomically: true, encoding: .utf8)
        r.rebuild()
        r.engine.start(watchConfig: false)
        expectEqual(r.engine.config, Config.default)
        expectEqual(r.errors.count, 1)
        expect(r.errors.first?.contains("не защищено") == true, "prominent error: \(r.errors)")
        try expectEqual(String(contentsOf: r.store.url, encoding: .utf8), "grace: [\n", "never overwritten")
        expect(!FileManager.default.fileExists(atPath: r.lastGood.path), "defaults are not 'last good'")
    }

    test("testLastGoodWrittenAfterSave") {
        let r = ERig(config: cfg())
        r.engine.start(watchConfig: false)
        r.engine.toggleApp("chatgpt")
        let lg = try ConfigStore(url: r.lastGood).load()
        expectEqual(lg.apps, ["telegram", "chatgpt"])
    }

    test("testNothingRefreezesAfterShutdown") {
        let r = ERig(config: cfg())
        r.engine.start(watchConfig: false)
        expectEqual(r.freezer.frozenPIDs, [100])
        r.engine.shutdown(deadline: 0)
        let stops = r.sig.pids(SIGSTOP).count
        r.engine.updateConfig { $0.apps = ["telegram"]; $0.grace = 5 }
        r.engine.toggleApp("chatgpt")
        r.engine.guardian.allowCurrentIP()
        _ = r.engine.allowCurrentCountry()
        r.engine.checkNow()
        r.clock.advance(by: 100)
        expectEqual(r.freezer.frozenPIDs, [], "nothing frozen after shutdown")
        expectEqual(r.sig.pids(SIGSTOP).count, stops)
        expectEqual(r.sig.pids(SIGTERM), [])
        try expectEqual(r.store.load().apps, ["telegram"], "no config writes after shutdown")
        try expectEqual(r.store.load().grace, 20)
    }

    test("testTestModeRefusesConfigWrites") {
        let r = ERig(config: cfg(), writesBlocked: "тестовый режим: настройки не сохраняются")
        let before = try String(contentsOf: r.store.url, encoding: .utf8)
        r.engine.start(watchConfig: false)
        r.engine.guardian.allowCurrentIP()
        try expectEqual(String(contentsOf: r.store.url, encoding: .utf8), before, "real config untouched")
        expect(!FileManager.default.fileExists(atPath: r.lastGood.path), "no last-good write either")
        expectEqual(r.notices.last, "тестовый режим: настройки не сохраняются")
        expectEqual(r.engine.config.allow.ips, ["5.6.7.8"], "applied in memory for the demo")
    }

    test("testTestModeDoesNotCreateConfigFile") {
        let r = ERig(config: nil, writesBlocked: "тестовый режим: настройки не сохраняются")
        expect(!FileManager.default.fileExists(atPath: r.store.url.path))
    }

    test("testErrorTextsHaveNoPaths") {
        let home = NSHomeDirectory(), user = NSUserName()
        let e = NSError(domain: NSCocoaErrorDomain, code: 513,
                        userInfo: [NSFilePathErrorKey: home + "/Library/Application Support/SafeNet/config.yaml",
                                   NSLocalizedDescriptionKey: "You don’t have permission to save “config.yaml” in \(home)"])
        let t = Engine.safeDescription(e)
        expect(!t.contains(home) && !t.contains(user) && !t.contains("/"), t)
        // Real failure: the config directory becomes read-only, then a save fails.
        let r = ERig(config: cfg())
        r.engine.start(watchConfig: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: r.dir.path)
        r.engine.toggleApp("chatgpt")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: r.dir.path)
        expectEqual(r.errors.count, 1, "\(r.errors)")
        for m in r.errors + r.notices {
            expect(!m.contains(home) && !m.contains(user) && !m.contains(r.dir.path) && !m.contains("/"), m)
            expect(!NoticeText.configError(m).body.contains(home))
        }
    }

    // MARK: Tiered polling (C1, ruling R1)

    test("testEngineTickAsksOnlyCheapServices") {
        let r = ERig(config: tiered())
        r.engine.start(watchConfig: false)
        r.engine.networkChanged(online)
        expectEqual(r.modes.last, .full, "start / network change: full fan-out")
        let fulls = r.modes.filter { $0 == .full }.count
        r.modes = []
        r.clock.advance(by: 30)
        expect(!r.modes.isEmpty, "the tick still checks")
        expectEqual(r.modes.filter { $0 == .full }.count, 0, "unchanged IP: quota-limited services untouched")
        expect(fulls >= 1)
        expectEqual(r.engine.status.state, .ok)
    }
    test("testEngineCheapUnchangedIPKeepsLastFullCountry") {
        let r = ERig(config: tiered())
        r.engine.start(watchConfig: false)
        r.engine.networkChanged(online)
        // GeoIP of the cheap services disagrees on the country of the same IP: IP only compared.
        r.cheapAnswers = [a("5.6.7.8", "NL"), a("5.6.7.8", "NL")]
        r.modes = []
        r.clock.advance(by: 5)
        expectEqual(r.modes, [.cheap])
        expectEqual(r.engine.status.confirmed, a("5.6.7.8", "RU"), "country from the last full confirmation")
        expectEqual(r.engine.status.state, .ok)
    }
    test("testEngineCheapChangedIPRunsFullFanOut") {
        let r = ERig(config: tiered())
        r.engine.start(watchConfig: false)
        r.engine.networkChanged(online)
        r.cheapAnswers = [a("9.9.9.9", "NL"), a("9.9.9.9", "NL")]
        r.answers = [a("9.9.9.9", "NL"), a("9.9.9.9", "NL"), a("9.9.9.9", "NL")]
        r.modes = []
        r.clock.advance(by: 5)
        expectEqual(r.modes, [.cheap, .full])
        expectEqual(r.engine.status.confirmed, a("9.9.9.9", "NL"), "new IP confirmed only by the full fan-out")
        expectEqual(r.engine.guardian.frozenApps, ["telegram"], "NL not allowed")
    }
    test("testEngineCheapFailureBelowQuorumFailsClosed") {
        let r = ERig(config: tiered())
        r.engine.start(watchConfig: false)
        r.engine.networkChanged(online)
        expectEqual(r.engine.status.state, .ok)
        r.cheapAnswers = [a("5.6.7.8", "RU")]        // one cheap service failed: below quorum 2
        r.answers = []                               // and the full fan-out gets nothing
        r.modes = []
        r.clock.advance(by: 5)
        expectEqual(r.modes, [.cheap, .full])
        expectEqual(r.engine.guardian.frozenApps, ["telegram"])
        if case .frozen(_, let reason, _) = r.engine.status.state { expectEqual(reason, .unconfirmed) }
        else { expect(false, "not frozen: \(r.engine.status.state)") }
    }
    test("testEngineNoPeriodicPollingWithoutProtectedApps") {
        let r = ERig(config: tiered(apps: []))
        r.engine.start(watchConfig: false)
        r.engine.networkChanged(online)
        let n = r.fetchCalls
        r.clock.advance(by: 3600)
        expectEqual(r.fetchCalls, n, "no polling at all without protected apps")
        r.engine.checkNow()
        expectEqual(r.fetchCalls, n + 1, "manual check still works")
        expectEqual(r.modes.last, .full)
        r.engine.toggleApp("telegram")
        expectEqual(r.modes.last, .full, "first protected app: fresh full check")
        expectEqual(r.fetchCalls, n + 2)
    }
    test("testEngineFullFanOutEveryTenMinutes") {
        let r = ERig(config: tiered())
        r.engine.start(watchConfig: false)
        r.engine.networkChanged(online)
        r.modes = []
        r.clock.advance(by: 599)
        expectEqual(r.modes.filter { $0 == .full }.count, 0)
        r.clock.advance(by: 6)
        expectEqual(r.modes.filter { $0 == .full }.count, 1, "10-minute full refresh")
        r.modes = []
        r.clock.advance(by: 60)
        expectEqual(r.modes.filter { $0 == .full }.count, 0)
    }
    test("testEngineWakeAndManualCheckAreFull") {
        let r = ERig(config: tiered())
        r.engine.start(watchConfig: false)
        r.engine.networkChanged(online)
        r.modes = []
        r.engine.checkNow()
        expectEqual(r.modes, [.full])
        r.modes = []
        r.engine.didWake()
        expect(!r.modes.isEmpty && r.modes.allSatisfy { $0 == .full }, "\(r.modes)")
    }
    test("testCheapConfirmsPureRule") {
        let full = [a("1.2.3.4", "NL"), a("1.2.3.4", "NL"), a("1.2.3.4", "NL"), a("2001:db8::7", "NL")]
        expect(Engine.cheapConfirms([a("1.2.3.4", "RU"), a("1.2.3.4", "RU")], last: full, minAgree: 2, cheapCount: 2))
        expect(!Engine.cheapConfirms([a("1.2.3.4", "NL")], last: full, minAgree: 2, cheapCount: 2), "below quorum")
        expect(Engine.cheapConfirms([a("1.2.3.4", "NL")], last: full, minAgree: 1, cheapCount: 2))
        expect(Engine.cheapConfirms([a("1.2.3.4", "NL"), a("1.2.3.4", "NL")], last: full, minAgree: 3, cheapCount: 2),
               "quorum capped at the number of cheap services")
        expect(!Engine.cheapConfirms([a("1.2.3.4", "NL"), a("4.4.4.4", "NL")], last: full, minAgree: 1, cheapCount: 2),
               "any different IP -> full")
        expect(Engine.cheapConfirms([a("1.2.3.4", "NL"), a("2001:db8::7", "NL")], last: full, minAgree: 2, cheapCount: 2),
               "dual stack: the known IPv6 exit counts as unchanged")
        expect(!Engine.cheapConfirms([a("1.2.3.4", "NL"), a("2001:db8::8", "NL")], last: full, minAgree: 2, cheapCount: 2))
        expect(!Engine.cheapConfirms([a("2001:db8::7", "NL"), a("2001:db8::7", "NL")], last: full, minAgree: 2, cheapCount: 2),
               "needs the IPv4 one too")
        expect(!Engine.cheapConfirms([a("1.2.3.4", "NL"), a("1.2.3.4", "NL")], last: [], minAgree: 2, cheapCount: 2),
               "no previous confirmation")
        expect(!Engine.cheapConfirms([], last: full, minAgree: 2, cheapCount: 2))
    }

    test("testEngineFirstRunEmptyAllowListNeverCloses") {
        var c = cfg(countries: []); c.routeCheck = false
        let r = ERig(config: c)
        r.engine.start(watchConfig: false)
        r.engine.networkChanged(online)
        expectEqual(r.engine.guardian.frozenApps, ["telegram"])
        if case .frozen(_, let reason, let d) = r.engine.status.state {
            expectEqual(reason, .noAllowList); expectEqual(d, nil)
        } else { expect(false, "not frozen: \(r.engine.status.state)") }
        r.clock.advance(by: 300)
        expectEqual(r.sig.pids(SIGTERM), [], "first run: frozen, never closed")
        expect(r.engine.allowCurrentCountry())
        expectEqual(r.engine.status.state, .ok)
    }

    test("testEngineRouteLeakPerAppNotUnion") {
        var c = cfg(apps: ["telegram", "chatgpt"], countries: ["RU"])
        c.appRules = ["chatgpt": AllowList(countries: ["NL"])]
        let r = ERig(config: c)
        r.table.procs.append(eproc(300, "ChatGPT"))
        r.answers = [a("5.6.7.8", "RU"), a("5.6.7.8", "RU")]
        r.routeResults = [RouteResult(host: "chatgpt.com", ip: "7.7.7.7", country: "RU", error: nil)]
        c.appRules["chatgpt"] = AllowList(ips: ["5.6.7.8"], countries: ["NL"])
        try? r.store.save(c)
        r.rebuild()
        r.engine.start(watchConfig: false)
        r.engine.networkChanged(online)
        r.clock.advance(by: 0.1)                     // route probe finished
        expectEqual(r.engine.guardian.frozenApps, ["chatgpt"], "route via RU: leak for ChatGPT (NL only), fine for Telegram")
        if case .frozen(_, let reason, _) = r.engine.status.state { expectEqual(reason, .routeLeak) }
        expectEqual(r.engine.status.observation?.routeLeak, true, "display flag: some app sees a leak")
    }

    test("testToggleAppIsCaseInsensitiveForPresets") {
        var c = cfg(); c.apps = ["Telegram"]           // e.g. set in code, not through the YAML loader
        let r = ERig(config: nil)
        try? r.store.save(c)
        r.rebuild()
        r.engine.start(watchConfig: false)
        expectEqual(r.engine.config.apps, ["telegram"], "normalised at load")
        r.engine.toggleApp("telegram")
        expectEqual(r.engine.config.apps, [], "toggle turns it off")
        r.engine.toggleApp("Telegram")
        expectEqual(r.engine.config.apps, ["telegram"], "canonical id appended")
        r.engine.toggleApp("TELEGRAM")
        expectEqual(r.engine.config.apps, [])
    }
}
