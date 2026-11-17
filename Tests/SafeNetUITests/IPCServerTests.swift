import Foundation
import Darwin
import SafeNetCore
@testable import SafeNetUI

// IPC server / CLI tests over REAL unix sockets in a temp directory (never the user's support
// dir), with a fake Engine (fake clock, process table, signaler, IP fetcher).

private final class IEmptyTable: ProcessTable {
    func list() -> [ProcInfo] { [] }
    func snapshot() -> [ProcInfo]? { [] }
}
private final class INoSignaler: Signaler {
    func send(_ sig: Int32, to pid: Int32) -> Bool { true }
}

private let iOnline = NetSnapshot(online: true, hasTunnel: true, gatewayIP: nil, gatewayMAC: nil, proxy: nil)

private final class IRig {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sn-ipc-\(UUID().uuidString.prefix(8))")
    var sock: String { dir.appendingPathComponent("safenet.sock").path }
    let eq = DispatchQueue(label: "test.engine")
    let store: ConfigStore
    var engine: Engine!
    var service: CLIService!
    var server: IPCServer!
    var panelCalls = 0
    var panelOK = true
    let paths: AppPaths

    init(config: Config? = nil, writesBlocked: String? = nil, testMode: TestMode? = nil,
         peerAllowed: @escaping (Int32) -> Bool = { IPCServer.peerIsSameUser($0) },
         readTimeout: TimeInterval = 2, replyTimeout: TimeInterval = 5, swallow: Bool = false) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        paths = AppPaths(dir: dir)
        store = ConfigStore(url: paths.config)
        var c = config ?? Config.default
        if config == nil { c.apps = ["telegram"]; c.allow = AllowList(ips: [], countries: ["NL"]); c.closeTimeout = 0 }
        try! store.save(c)
        let clock = FakeClock(start: Date(timeIntervalSince1970: 1_800_000_000))
        let freezer = Freezer(table: IEmptyTable(), signaler: INoSignaler(), journal: paths.journal,
                              selfPID: 7, myUID: getuid(), pollInterval: 0.01)
        var deps = EngineDeps(
            clock: clock, freezer: freezer, log: EventLog(url: paths.events), store: store,
            fetchAnswers: { cb in cb([IPAnswer(ip: "1.2.3.4", country: "RU"), IPAnswer(ip: "1.2.3.4", country: "RU")]) },
            probeRoutes: { _, cb in cb([]) }, resolvers: { [] }, snapshotNow: { iOnline }, queue: nil)
        deps.configWritesBlocked = writesBlocked
        engine = Engine(deps: deps)
        eq.sync { engine.start(watchConfig: false); engine.networkChanged(iOnline) }
        let e = engine!, q = eq
        service = CLIService(perform: { body in q.async { body(e) } }, paths: paths, testMode: testMode,
                             configReadOnly: writesBlocked != nil,
                             openPanel: { [unowned self] done in self.panelCalls += 1; done(self.panelOK) }, version: "9.9.9")
        let svc = service!
        server = IPCServer(path: sock, readTimeout: readTimeout, replyTimeout: replyTimeout, peerAllowed: peerAllowed,
                           handler: swallow ? { _, _ in } : { svc.handle($0, reply: $1) })
    }

    func ask(_ c: CLICommand) -> IPCResponse? {
        if case .success(let r) = IPCClient.send(c, path: sock, timeout: 3) { return r }
        return nil
    }

    deinit {
        server.stop()
        eq.sync { _ = engine.shutdown(deadline: 0.1) }
        try? FileManager.default.removeItem(at: dir)
    }
}

private func mode(_ path: String) -> mode_t {
    var st = stat(); lstat(path, &st); return st.st_mode & 0o777
}

func registerIPCServerTests() {
    test("testSocketPathInSupportDirAndShortFallback") {
        let p = AppPaths(dir: URL(fileURLWithPath: "/tmp/x-safenet", isDirectory: true))
        expectEqual(p.socketPath, "/tmp/x-safenet/safenet.sock")
        let long = AppPaths(dir: URL(fileURLWithPath: "/tmp/" + String(repeating: "d", count: 120), isDirectory: true))
        let s = long.socketPath(tempDir: "/var/folders/ab/cdef/T/")
        expect(s.utf8.count <= AppPaths.maxSocketPath, "fits sun_path: \(s)")
        expect(s.hasPrefix("/var/folders/ab/cdef/T/safenet-\(getuid())/") && s.hasSuffix(".sock"), s)
        expectEqual(s, long.socketPath(tempDir: "/var/folders/ab/cdef/T/"))
        let other = AppPaths(dir: URL(fileURLWithPath: "/tmp/" + String(repeating: "e", count: 120), isDirectory: true))
        expect(other.socketPath(tempDir: "/var/folders/ab/cdef/T/") != s, "different dirs, different sockets")
        let huge = long.socketPath(tempDir: "/" + String(repeating: "t", count: 150))
        expect(huge.utf8.count <= AppPaths.maxSocketPath && huge.hasPrefix("/tmp/safenet-"), huge)
    }

    test("testSocketPathHonoursConfigDirEnvironment") {
        let p = AppPaths.from(environment: ["SAFENET_CONFIG_DIR": "/tmp/sn-env-test"])
        expectEqual(p.socketPath, "/tmp/sn-env-test/safenet.sock")
    }

    test("testIPCStatusOverRealSocket") {
        let r = IRig(testMode: TestMode(fakeAnswer: IPAnswer(ip: "1.2.3.4", country: "RU"), offline: false))
        try r.server.start()
        guard let resp = r.ask(.status) else { return expect(false, "no response") }
        expect(resp.ok)
        expect(resp.text.contains("Приложения заморожены"), resp.text)
        expect(resp.text.contains("страна не разрешена"), resp.text)
        expect(resp.text.contains("1.2.3.4 (RU)"), resp.text)
        expect(resp.text.contains("VPN-туннель: да"), resp.text)
        expect(resp.text.contains("Telegram: заморожено") || resp.text.contains("Telegram: под защитой"), resp.text)
        expect(resp.text.contains("ТЕСТОВЫЙ РЕЖИМ"), resp.text)
        expect(resp.text.contains(r.paths.config.path), "config path")
        expect(!resp.text.contains("allow"), "no config content")
    }

    test("testIPCAllowCountryIPAndCurrent") {
        let r = IRig()
        try r.server.start()
        let c1 = r.ask(.allow("NL"))
        expectEqual(c1?.ok, false, "NL already allowed is an error from AllowInput")
        let c2 = r.ask(.allow("DE"))
        expectEqual(c2?.ok, true); expect(c2?.text.contains("DE") == true)
        let c3 = r.ask(.allow("185.12.40.0/24"))
        expectEqual(c3?.ok, true); expect(c3?.text.contains("подсеть") == true, c3?.text ?? "")
        let c4 = r.ask(.allow(nil))                         // current confirmed IP 1.2.3.4
        expectEqual(c4?.ok, true); expect(c4?.text.contains("1.2.3.4") == true, c4?.text ?? "")
        let c5 = r.ask(.allow(nil))
        expectEqual(c5?.ok, true); expect(c5?.text.contains("уже разрешён") == true, c5?.text ?? "")
        let saved = try r.store.load()
        expectEqual(saved.allow.countries, ["NL", "DE"])
        expectEqual(saved.allow.ips, ["185.12.40.0/24", "1.2.3.4"])
        r.eq.sync { expectEqual(r.engine.status.state, .ok, "now allowed, apps resume") }
        let bad = r.ask(.allow("ZZ"))
        expectEqual(bad?.ok, false)
        let wide = r.ask(.allow("10.0.0.0/4"))
        expect(wide?.text.contains("Внимание") == true, wide?.text ?? "")
    }

    test("testIPCAllowUnconfirmedCurrentIsRefused") {
        let r = IRig()
        r.eq.sync { r.engine.networkChanged(NetSnapshot(online: false, hasTunnel: false, gatewayIP: nil, gatewayMAC: nil, proxy: nil)) }
        try r.server.start()
        let resp = r.ask(.allow(nil))
        expectEqual(resp?.ok, false)
        expect(resp?.text.contains("не подтверждён") == true, resp?.text ?? "")
        try expectEqual(r.store.load().allow.ips, [])
    }

    test("testIPCAllowInTestModeWithoutConfigDirIsRefused") {
        let r = IRig(writesBlocked: LiveSystem.readOnlyMessage)
        try r.server.start()
        let resp = r.ask(.allow("DE"))
        expectEqual(resp?.ok, false)
        expect(resp?.text.contains("не сохраняются") == true, resp?.text ?? "")
        try expectEqual(r.store.load().allow.countries, ["NL"], "nothing written to disk")
    }

    test("testIPCAllowOnBrokenConfigKeepsBackup") {
        let r = IRig()
        try "apps: [telegram\n  : : broken".write(to: r.store.url, atomically: true, encoding: .utf8)
        // Engine created after the file broke: fileBroken = true at init
        let freezer = Freezer(table: IEmptyTable(), signaler: INoSignaler(), journal: r.paths.journal, selfPID: 7, myUID: getuid(), pollInterval: 0.01)
        let deps = EngineDeps(clock: FakeClock(start: Date(timeIntervalSince1970: 1_800_000_000)), freezer: freezer,
                              log: EventLog(url: r.paths.events), store: r.store,
                              fetchAnswers: { cb in cb([]) }, probeRoutes: { _, cb in cb([]) }, resolvers: { [] },
                              snapshotNow: { iOnline }, queue: nil)
        let e2 = Engine(deps: deps)
        e2.start(watchConfig: false)
        let out = CLIService.allow("DE", engine: e2)
        expectEqual(out.ok, true, out.text)
        let backups = (try FileManager.default.contentsOfDirectory(atPath: r.dir.path)).filter { $0.hasPrefix("config.broken-") }
        expectEqual(backups.count, 1, "broken file copied before overwrite")
        _ = e2.shutdown(deadline: 0.1)
    }

    test("testIPCConfigVersionPanel") {
        let r = IRig()
        try r.server.start()
        expectEqual(r.ask(.config)?.text, r.paths.config.path)
        expectEqual(r.ask(.version)?.text, "SafeNet 9.9.9")
        let p = r.ask(.panel)
        expectEqual(p?.ok, true); expectEqual(r.panelCalls, 1)
        r.panelOK = false
        expectEqual(r.ask(.panel)?.ok, false)
    }

    test("testIPCSocketPermissionsAndStopRemoves") {
        let r = IRig()
        try r.server.start()
        expectEqual(mode(r.sock), 0o600, "socket mode")
        expectEqual(mode(r.dir.path), 0o700, "dir mode")
        r.server.stop()
        expect(!FileManager.default.fileExists(atPath: r.sock), "socket removed on stop")
        expectEqual(IPCClient.send(.version, path: r.sock, timeout: 1).failureValue, .notRunning)
        r.server.stop()                                     // idempotent
        try r.server.start()                                // restartable
        expectEqual(r.ask(.version)?.ok, true)
    }

    test("testIPCStaleSocketIsReplacedLiveOneIsNot") {
        let r = IRig()
        // A stale socket file: bound, then abandoned (nobody listens).
        var addr = sockaddr_un()
        expect(IPCServer.fill(&addr, path: r.sock))
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        close(fd)
        expect(FileManager.default.fileExists(atPath: r.sock), "stale file in place")
        try r.server.start()
        expectEqual(r.ask(.version)?.ok, true, "stale socket replaced")
        // A second server on a live socket must not steal it.
        let second = IPCServer(path: r.sock, handler: { _, reply in reply(IPCResponse(ok: true, text: "intruder")) })
        do { try second.start(); expect(false, "second server must not start") }
        catch { expectEqual(error as? IPCServerError, .alreadyRunning) }
        expectEqual(r.ask(.version)?.text, "SafeNet 9.9.9", "live server untouched")
        second.stop()
        expect(FileManager.default.fileExists(atPath: r.sock), "a server that never started removes nothing")
    }

    test("testIPCForeignFileAtSocketPathIsKept") {
        let r = IRig()
        try "precious".write(toFile: r.sock, atomically: true, encoding: .utf8)
        do { try r.server.start(); expect(false, "must not start over a regular file") } catch {}
        try expectEqual(String(contentsOfFile: r.sock), "precious")
    }

    test("testIPCRejectsDirectoryOfAnotherOwnerOrSymlink") {
        let r = IRig()
        let link = r.dir.appendingPathComponent("lnk").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: r.dir.path)
        expectThrows { try IPCServer.prepareDirectory(link, strict: true) }
        try IPCServer.prepareDirectory(link, strict: false)
        expectThrows { try IPCServer.prepareDirectory(r.paths.config.path, strict: false) }   // a file, not a dir
    }

    test("testPeerCredentialCheck") {
        expect(IPCServer.peerUIDAllowed(501, me: 501))
        expect(!IPCServer.peerUIDAllowed(0, me: 501), "root is not us either")
        expect(!IPCServer.peerUIDAllowed(502, me: 501))
        var fds: [Int32] = [0, 0]
        expectEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        expect(IPCServer.peerIsSameUser(fds[0]), "real getpeereid on a pair made by us")
        close(fds[0]); close(fds[1])
        expect(!IPCServer.peerIsSameUser(-1), "unreadable credentials -> denied")
    }

    test("testIPCDeniedPeerGetsNoAnswerAndNoAction") {
        let r = IRig(peerAllowed: { _ in false })
        try r.server.start()
        if case .success = IPCClient.send(.allow("DE"), path: r.sock, timeout: 1) { expect(false, "must be dropped") }
        try expectEqual(r.store.load().allow.countries, ["NL"])
    }

    test("testIPCGarbageAndOversizedClientsDoNotBreakServer") {
        let r = IRig()
        try r.server.start()
        func raw(_ d: Data, close: Bool = false) -> IPCResponse? {
            if case .success(let line) = IPCClient.exchange(d, path: r.sock, timeout: 2, shutdownWrite: close) { return try? decodeResponse(line) }
            return nil
        }
        expectEqual(raw(Data("garbage\n".utf8))?.ok, false)
        expectEqual(raw(Data("{\"v\":9,\"cmd\":\"status\"}\n".utf8))?.ok, false)
        expectEqual(raw(Data("{\"v\":1,\"cmd\":\"allow\",\"arg\":\"../../x\"}\n".utf8))?.ok, false)
        expectEqual(raw(Data([0xFF, 0x00, 0xFE, 0x0A]))?.ok, false)
        let big = Data(repeating: 0x41, count: ipcMaxMessage * 4) + Data("\n".utf8)
        let resp = raw(big)
        expect(resp == nil || resp?.ok == false, "oversized request never succeeds")
        expectEqual(raw(Data("{\"v\":1,\"cmd\":\"version\"}".utf8), close: true)?.ok, true, "EOF instead of newline still parses")
        expectEqual(r.ask(.version)?.ok, true, "server alive")
        try expectEqual(r.store.load().allow.countries, ["NL"])
    }

    test("testIPCSlowAndVanishingClientsDoNotHang") {
        let r = IRig(readTimeout: 0.3)
        try r.server.start()
        // Slow: connects, sends half a line, then idles. Must be dropped by the read deadline.
        guard case .success(let fd) = IPCClient.connect(path: r.sock, timeout: 1) else { return expect(false, "connect") }
        _ = IPCIO.write(fd, Data("{\"v\":1,".utf8), timeout: 1)
        let t0 = Date()
        let line = IPCIO.readLine(fd, timeout: 3)
        close(fd)
        if case .success = line { expect(false, "no response expected") }
        expect(Date().timeIntervalSince(t0) < 2, "dropped by the server's deadline")
        // Vanishing: connect and close at once; send then close before the answer.
        for _ in 0..<5 {
            if case .success(let f) = IPCClient.connect(path: r.sock, timeout: 1) { close(f) }
            if case .success(let f) = IPCClient.connect(path: r.sock, timeout: 1) {
                _ = IPCIO.write(f, encodeMessage(IPCRequest(.status)), timeout: 1); close(f)
            }
        }
        let dbg = IPCClient.send(.version, path: r.sock, timeout: 3)
        expect({ if case .success(let x) = dbg { return x.ok }; return false }(), "server alive: \(dbg)")
    }

    test("testIPCHandlerThatNeverRepliesTimesOut") {
        let r = IRig(replyTimeout: 0.3, swallow: true)
        try r.server.start()
        let t0 = Date()
        let resp = r.ask(.status)
        expectEqual(resp?.ok, false)
        expect(Date().timeIntervalSince(t0) < 3)
    }

    test("testIPCManyConcurrentClients") {
        let r = IRig()
        try r.server.start()
        let group = DispatchGroup()
        let lock = NSLock(); var okCount = 0, busyCount = 0, other = 0
        for _ in 0..<20 {
            group.enter()
            DispatchQueue.global().async {
                let res = IPCClient.send(.version, path: r.sock, timeout: 3)
                lock.lock()
                if case .success(let x) = res {
                    if x.ok { okCount += 1 } else if x.text.contains("занят") { busyCount += 1 } else { other += 1 }
                } else { other += 1 }
                lock.unlock()
                group.leave()
            }
        }
        expectEqual(group.wait(timeout: .now() + 20), .success, "no client hangs")
        expectEqual(okCount + busyCount, 20, "every client got ok or busy (ok \(okCount), busy \(busyCount), other \(other))")
        expectEqual(other, 0)
        expectEqual(r.ask(.version)?.ok, true, "server answers afterwards")
    }

    test("testIPCEarlyDisconnectsNeverKillTheProcess") {
        // SIGPIPE regression: a client that sends a request and closes at once must not terminate
        // the server process (the reply write hits a closed peer). Deliberately NOT ignoring the
        // signal here: the server itself has to make the process safe.
        let r = IRig()
        try r.server.start()
        for i in 0..<200 {
            guard case .success(let fd) = IPCClient.connect(path: r.sock, timeout: 1) else { continue }
            _ = IPCIO.write(fd, encodeMessage(IPCRequest(i % 2 == 0 ? .status : .version)), timeout: 1)
            close(fd)
        }
        // Over-the-cap "busy" path with a vanished peer as well.
        for _ in 0..<40 {
            if case .success(let fd) = IPCClient.connect(path: r.sock, timeout: 1) { close(fd) }
        }
        var ok = false
        for _ in 0..<20 where !ok { ok = r.ask(.version)?.ok == true; if !ok { usleep(100_000) } }
        expect(ok, "still alive and answering after 240 early disconnects")
    }

    // MARK: Status text

    test("testStatusTextStates") {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var cfg = Config.default; cfg.apps = ["telegram"]
        var s = EngineStatus()
        s.state = .ok
        expect(CLIStatusText.make(status: s, config: cfg, configPath: "/c.yaml", testMode: nil, configReadOnly: false, now: now)
            .hasPrefix("Защита включена"))
        s.state = .frozen(since: now, reason: .offline, deadline: now.addingTimeInterval(42))
        s.frozenApps = ["telegram"]
        let f = CLIStatusText.make(status: s, config: cfg, configPath: "/c.yaml", testMode: nil, configReadOnly: false, now: now)
        expect(f.contains("закрытие через 42 с") && f.contains("нет сети") && f.contains("Telegram: заморожено"), f)
        s.state = .closed(now); s.frozenApps = []; s.closedApps = ["telegram"]
        let c = CLIStatusText.make(status: s, config: cfg, configPath: "/c.yaml", testMode: nil, configReadOnly: false, now: now)
        expect(c.hasPrefix("Закрыто") && c.contains("Telegram: закрыто"), c)
        s.state = .paused(until: now.addingTimeInterval(600))
        let p = CLIStatusText.make(status: s, config: cfg, configPath: "/c.yaml", testMode: nil, configReadOnly: true, now: now)
        expect(p.hasPrefix("Пауза до ") && p.contains(":"), p)
        let t = CLIStatusText.make(status: s, config: cfg, configPath: "/c.yaml",
                                   testMode: TestMode(fakeAnswer: nil, offline: true), configReadOnly: true, now: now)
        expect(t.contains("ТЕСТОВЫЙ РЕЖИМ (настройки не сохраняются)"), t)
        expect(t.contains("IP: нет ответа"), t)
    }

    // MARK: Console client

    test("testCLIClientNotRunningConfigVersionUsage") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sn-cli-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = ["SAFENET_CONFIG_DIR": dir.path]
        var out: [String] = [], err: [String] = []
        func run(_ a: [String]) -> Int32 {
            out = []; err = []
            return runCLIClient(a, environment: env, out: { out.append($0) }, err: { err.append($0) })
        }
        expectEqual(run(["status"]), 3)
        expect(err.joined().contains("не запущен"), err.joined())
        expectEqual(run(["allow", "RU"]), 3)
        expectEqual(run(["panel"]), 3)
        expectEqual(run(["config"]), 0)
        expectEqual(out, [dir.appendingPathComponent("config.yaml").path])
        expectEqual(run(["version"]), 0)
        expect(out.joined().hasPrefix("SafeNet "))
        expectEqual(run(["allow", "bad!"]), 2)
        expect(err.joined().contains("Использование"))
        expectEqual(run([]), 2)
        expectEqual(run(["status", "x"]), 2)
        expectEqual(run(["--help"]), 0)
        expect(!FileManager.default.fileExists(atPath: dir.path), "client creates nothing on disk")
    }

    test("testCLIClientTalksToServer") {
        let r = IRig()
        try r.server.start()
        let env = ["SAFENET_CONFIG_DIR": r.dir.path]
        var out: [String] = [], err: [String] = []
        func run(_ a: [String]) -> Int32 {
            out = []; err = []
            return runCLIClient(a, environment: env, out: { out.append($0) }, err: { err.append($0) })
        }
        expectEqual(run(["status"]), 0)
        expect(out.joined().contains("Telegram"), out.joined())
        expectEqual(run(["allow", "de"]), 0)
        try expectEqual(r.store.load().allow.countries, ["NL", "DE"])
        expectEqual(run(["allow", "de"]), 1, "already in the list: error exit code")
        expect(!err.isEmpty)
        expectEqual(run(["panel"]), 0)
        expectEqual(r.panelCalls, 1)
    }

    test("testIsCLIInvocation") {
        expect(isCLIInvocation(["x", "status"]))
        expect(isCLIInvocation(["x", "bogus"]), "unknown word: usage, never a second app")
        expect(isCLIInvocation(["x", "--version"]))
        expect(!isCLIInvocation(["x"]))
        expect(!isCLIInvocation(["x", "--watchdog", "1", "p"]))
        expect(!isCLIInvocation(["x", "-psn_0_12345"]))
    }

    // MARK: Engine.updateConfig result

    test("testUpdateConfigResult") {
        let r = IRig()
        r.eq.sync {
            expectEqual(r.engine.updateConfig { $0.allow.countries.append("DE") }, .saved)
            expectEqual(r.engine.updateConfig { _ in }, .unchanged)
        }
        let b = IRig(writesBlocked: "нельзя")
        b.eq.sync { expectEqual(b.engine.updateConfig { $0.allow.countries.append("DE") }, .refused("нельзя")) }
    }
}

private extension Result {
    var failureValue: Failure? { if case .failure(let e) = self { return e } else { return nil } }
}
