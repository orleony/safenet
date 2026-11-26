import Foundation
import CryptoKit
@testable import SafeNetCore

private func tmpDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("sn-upd-\(tag)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func manifestJSON(version: String = "1.2.0", url: String = "https://github.com/o/r/releases/download/v1.2.0/SafeNet-1.2.0.zip",
                          sha: String = String(repeating: "a", count: 64), size: Int = 1000, min: String? = nil) -> Data {
    var d: [String: Any] = ["version": version, "url": url, "sha256": sha, "size": size]
    if let m = min { d["minimum_system"] = m }
    return try! JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])
}

/// Installer against a temp directory: real file operations, simulated processes.
private final class FakeInstallerSystem: InstallerSystem {
    var parentExits = true
    var invalidReason: String?
    var failCopy = false
    var failSecondRename = false
    /// The launched app confirms (removes the pending marker), like a healthy new version.
    var confirms = true
    var launches: [URL] = []
    var stopped: [URL] = []
    var renames = 0
    var clock = Date(timeIntervalSince1970: 1_000_000)
    let pending: URL

    init(stateDir: URL) { pending = UpdateMarkers(dir: stateDir).pending }

    func waitForExit(_ pid: Int32, timeout: TimeInterval) -> Bool { parentExits }
    func validate(app: URL, bundleID: String, version: String) -> String? { invalidReason }
    func copy(_ from: URL, to: URL) throws {
        if failCopy { throw UpdateError.install("copy") }
        try FileManager.default.copyItem(at: from, to: to)
    }
    func rename(_ from: URL, to: URL) throws {
        renames += 1
        if failSecondRename && renames == 2 { throw UpdateError.install("rename") }
        try FileManager.default.moveItem(at: from, to: to)
    }
    func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func clearAttributes(_ url: URL) {}
    func launch(_ app: URL) -> Bool {
        launches.append(app)
        if confirms { try? FileManager.default.removeItem(at: pending) }
        return true
    }
    func stopInstances(of app: URL) { stopped.append(app) }
    func sleep(_ seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds) }
    var now: Date { clock }
}

/// A fake bundle: Contents/marker holds `content`, so a test can see which version is installed.
private func makeBundle(_ url: URL, content: String) {
    try? FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try? content.write(to: url.appendingPathComponent("Contents/marker"), atomically: true, encoding: .utf8)
}

private func marker(_ app: URL) -> String? {
    try? String(contentsOf: app.appendingPathComponent("Contents/marker"), encoding: .utf8)
}

private struct InstallRig {
    let root = tmpDir("inst")
    var state: URL { root.appendingPathComponent("state", isDirectory: true) }
    var apps: URL { root.appendingPathComponent("Applications", isDirectory: true) }
    var target: URL { apps.appendingPathComponent("SafeNet.app") }
    var staged: URL { UpdateMarkers(dir: state).staging.appendingPathComponent("1.1.0/SafeNet.app") }
    let sys: FakeInstallerSystem

    init() {
        sys = FakeInstallerSystem(stateDir: root.appendingPathComponent("state", isDirectory: true))
        makeBundle(target, content: "old")
        makeBundle(staged, content: "new")
    }

    var plan: UpdateInstaller.Plan {
        UpdateInstaller.Plan(parentPID: 4242, staged: staged, target: target, stateDir: state,
                             bundleID: "local.safenet.app", fromVersion: "1.0.0", toVersion: "1.1.0")
    }

    func run() -> UpdateInstaller.Outcome { UpdateInstaller(system: sys).run(plan) }
    var result: UpdateMarkers.Result? { UpdateMarkers(dir: state).takeResult() }
    /// Hidden .new / .old / .failed copies left next to the installed app.
    var leftovers: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: apps.path)) ?? []).filter { $0.hasPrefix(".") }
    }
}

func registerUpdateTests() {
    test("testAppVersionParseCompare") {
        expectEqual(AppVersion("1.2.3")?.description, "1.2.3")
        expectEqual(AppVersion("2")?.description, "2.0.0")
        expectEqual(AppVersion(" 1.10 ")?.description, "1.10.0")
        expect(AppVersion("1.10.0")! > AppVersion("1.9.9")!, "numeric, not lexical")
        expect(AppVersion("1.0.0")! == AppVersion("1.0")!)
        expect(AppVersion("1.0.1")! > AppVersion("1.0.0")!)
        for bad in ["", "1.", ".1", "1.2.3.4", "v1.2", "1.a", "-1", "1..2", "1.2.3-beta", "9999999"] {
            expect(AppVersion(bad) == nil, "must reject \(bad)")
        }
        expectEqual(AppVersion("1.2.3")?.buildNumber, 10203)
        expectEqual(AppVersion("1.100.0")?.buildNumber, nil)
    }

    test("testManifestDecodeStrict") {
        let m = try UpdateManifest.decode(manifestJSON(min: "13.0"))
        expectEqual(m.version, "1.2.0")
        expectEqual(m.minimumSystem, "13.0")
        expectThrows { _ = try UpdateManifest.decode(manifestJSON(url: "http://github.com/x.zip")) }
        expectThrows { _ = try UpdateManifest.decode(manifestJSON(url: "file:///tmp/x.zip")) }
        expectThrows { _ = try UpdateManifest.decode(manifestJSON(sha: "ABC")) }
        expectThrows { _ = try UpdateManifest.decode(manifestJSON(sha: String(repeating: "A", count: 64))) }
        expectThrows { _ = try UpdateManifest.decode(manifestJSON(size: 0)) }
        expectThrows { _ = try UpdateManifest.decode(manifestJSON(size: UpdateManifest.maxSize + 1)) }
        expectThrows { _ = try UpdateManifest.decode(manifestJSON(version: "latest")) }
        expectThrows { _ = try UpdateManifest.decode(manifestJSON(min: "fourteen")) }
        expectThrows { _ = try UpdateManifest.decode(Data("not json".utf8)) }
    }

    test("testSignatureVerify") {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        let data = manifestJSON()
        let sig = try key.signature(for: data).base64EncodedString()
        expect(UpdateSignature.verify(data, signature: sig + "\n", publicKey: pub), "trailing newline of the .sig file")
        var tampered = data; tampered[tampered.count - 2] ^= 1
        expect(!UpdateSignature.verify(tampered, signature: sig, publicKey: pub), "tampered manifest")
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        expect(!UpdateSignature.verify(data, signature: sig, publicKey: other), "another key")
        expect(!UpdateSignature.verify(data, signature: "garbage", publicKey: pub))
        expect(!UpdateSignature.verify(data, signature: sig, publicKey: ""))
        expect(!UpdateSignature.verify(data, signature: sig, publicKey: "AAAA"))
    }

    test("testUpdateDecision") {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        func signed(_ d: Data) -> String { try! key.signature(for: d).base64EncodedString() }
        let sys = AppVersion("13.6")!
        let newer = manifestJSON(version: "1.2.0")
        try expectEqual(UpdateDecision.evaluate(manifest: newer, signature: signed(newer), publicKey: pub,
                                                current: AppVersion("1.1.9")!, system: sys)?.version, "1.2.0")
        try expect(UpdateDecision.evaluate(manifest: newer, signature: signed(newer), publicKey: pub,
                                           current: AppVersion("1.2.0")!, system: sys) == nil, "same version")
        try expect(UpdateDecision.evaluate(manifest: newer, signature: signed(newer), publicKey: pub,
                                           current: AppVersion("2.0.0")!, system: sys) == nil, "never a downgrade")
        let needs14 = manifestJSON(version: "1.2.0", min: "14.0")
        try expect(UpdateDecision.evaluate(manifest: needs14, signature: signed(needs14), publicKey: pub,
                                           current: AppVersion("1.0.0")!, system: sys) == nil, "needs newer macOS")
        do {
            _ = try UpdateDecision.evaluate(manifest: newer, signature: signed(manifestJSON(version: "9.9.9")), publicKey: pub,
                                            current: AppVersion("1.0.0")!, system: sys)
            expect(false, "signature of other bytes must throw")
        } catch { expectEqual(error as? UpdateError, .badSignature) }
        do {
            _ = try UpdateDecision.evaluate(manifest: newer, signature: signed(newer), publicKey: "  ",
                                            current: AppVersion("1.0.0")!, system: sys)
            expect(false, "no key must throw")
        } catch { expectEqual(error as? UpdateError, .notConfigured) }
        // A correctly signed but malformed manifest is still refused.
        let bad = manifestJSON(url: "http://evil.example/x.zip")
        expectThrows { _ = try UpdateDecision.evaluate(manifest: bad, signature: signed(bad), publicKey: pub,
                                                       current: AppVersion("1.0.0")!, system: sys) }
    }

    test("testSHA256OfFile") {
        let d = tmpDir("sha")
        let f = d.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: f)
        expectEqual(sha256Hex(file: f), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        expect(sha256Hex(file: d.appendingPathComponent("missing")) == nil)
        try? FileManager.default.removeItem(at: d)
    }

    test("testInstallPlanArguments") {
        let p = UpdateInstaller.Plan(parentPID: 77, staged: URL(fileURLWithPath: "/s/updates/1.1.0/SafeNet.app"),
                                     target: URL(fileURLWithPath: "/Applications/SafeNet.app"),
                                     stateDir: URL(fileURLWithPath: "/s", isDirectory: true),
                                     bundleID: "local.safenet.app", fromVersion: "1.0.0", toVersion: "1.1.0")
        expectEqual(UpdateInstaller.Plan(arguments: p.arguments), p)
        var a = p.arguments
        a[0] = "1"; expect(UpdateInstaller.Plan(arguments: a) == nil, "pid 1")
        a = p.arguments; a[2] = "Applications/SafeNet.app"; expect(UpdateInstaller.Plan(arguments: a) == nil, "relative")
        a = p.arguments; a[2] = "/Applications/SafeNet"; expect(UpdateInstaller.Plan(arguments: a) == nil, "not .app")
        a = p.arguments; a[2] = "/Applications/../tmp/SafeNet.app"; expect(UpdateInstaller.Plan(arguments: a) == nil, "..")
        a = p.arguments; a[6] = "next"; expect(UpdateInstaller.Plan(arguments: a) == nil, "version")
        expect(UpdateInstaller.Plan(arguments: Array(p.arguments.dropLast())) == nil)
    }

    test("testInstallerReplacesBundle") {
        let r = InstallRig()
        expectEqual(r.run(), .installed)
        expectEqual(marker(r.target), "new")
        expectEqual(r.sys.launches, [r.target])
        expectEqual(r.leftovers, [], "no .new/.old copies left")
        expect(!FileManager.default.fileExists(atPath: r.staged.deletingLastPathComponent().path), "staged copy removed")
        let res = r.result
        expectEqual(res?.ok, true); expectEqual(res?.to, "1.1.0")
        expect(r.result == nil, "the result is shown once")
        try? FileManager.default.removeItem(at: r.root)
    }

    test("testInstallerWaitsForAppToQuit") {
        let r = InstallRig()
        r.sys.parentExits = false
        guard case .aborted = r.run() else { return expect(false, "aborted") }
        expectEqual(marker(r.target), "old")
        expectEqual(r.sys.launches, [], "the app still runs: nothing relaunched")
        expectEqual(r.result?.ok, false)
        try? FileManager.default.removeItem(at: r.root)
    }

    test("testInstallerRefusesInvalidBundle") {
        let r = InstallRig()
        r.sys.invalidReason = "другое приложение"
        expectEqual(r.run(), .aborted("другое приложение"))
        expectEqual(marker(r.target), "old")
        expectEqual(r.sys.launches, [r.target], "the old version is started again")
        expectEqual(r.leftovers, [])
        try? FileManager.default.removeItem(at: r.root)
    }

    test("testInstallerCopyOrRenameFailureKeepsOld") {
        let r = InstallRig()
        r.sys.failCopy = true
        guard case .aborted = r.run() else { return expect(false, "aborted on copy") }
        expectEqual(marker(r.target), "old"); expectEqual(r.leftovers, [])
        let r2 = InstallRig()
        r2.sys.failSecondRename = true
        guard case .aborted = r2.run() else { return expect(false, "aborted on rename") }
        expectEqual(marker(r2.target), "old", "old bundle put back")
        expectEqual(r2.leftovers, [])
        expectEqual(r2.sys.launches, [r2.target])
        try? FileManager.default.removeItem(at: r.root); try? FileManager.default.removeItem(at: r2.root)
    }

    test("testInstallerRollsBackWhenNewVersionDoesNotStart") {
        let r = InstallRig()
        r.sys.confirms = false
        guard case .rolledBack = r.run() else { return expect(false, "rolled back") }
        expectEqual(marker(r.target), "old", "old version restored")
        expectEqual(r.sys.launches, [r.target, r.target], "new tried, old started again")
        expectEqual(r.sys.stopped, [r.target], "the hung new instance is stopped first")
        expectEqual(r.leftovers, [])
        expect(!FileManager.default.fileExists(atPath: UpdateMarkers(dir: r.state).pending.path), "pending marker gone")
        let res = r.result
        expectEqual(res?.ok, false); expect(res?.message.contains("возвращена версия 1.0.0") == true, res?.message ?? "")
        try? FileManager.default.removeItem(at: r.root)
    }

    test("testUpdateMarkersConfirmOnlyThatVersion") {
        let d = tmpDir("mark")
        let m = UpdateMarkers(dir: d)
        m.write(UpdateMarkers.Pending(version: "1.1.0", pid: 5), to: m.pending)
        expect(!m.confirmLaunch(version: "1.0.0"), "the old version starting is not a confirmation")
        expect(FileManager.default.fileExists(atPath: m.pending.path))
        expect(m.confirmLaunch(version: "1.1.0"))
        expect(!FileManager.default.fileExists(atPath: m.pending.path))
        expect(!m.confirmLaunch(version: "1.1.0"), "nothing pending")
        try? FileManager.default.removeItem(at: d)
    }

    test("testConfigUpdatesKey") {
        expectEqual(Config.default.updates, .auto)
        let c = try Config(yaml: MiniYAML.parse("updates: notify\n"))
        expectEqual(c.updates, .notify)
        expectThrows { _ = try Config(yaml: MiniYAML.parse("updates: sometimes\n")) }
        var o = Config.default; o.updates = .off
        try expectEqual(Config(yaml: o.toYAML()).updates, .off)
    }
}
