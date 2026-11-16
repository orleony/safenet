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
            fetchAnswers: { [unowned self] cb in
                self.fetchCalls += 1
                let now = self.answers               // answers as seen when the fetch started
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
}
