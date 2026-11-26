import Foundation
import CryptoKit
import SafeNetCore
@testable import SafeNetUI

/// Serves the manifest, its signature and the archive from memory / a local file.
private final class FakeFetcher: UpdateFetcher {
    var manifest: Data?
    var signature: String?
    var archive: URL?
    var requested: [String] = []

    func data(_ url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        requested.append(url.lastPathComponent)
        if url.lastPathComponent.hasSuffix(".sig") {
            completion(signature.map { .success(Data($0.utf8)) } ?? .failure(UpdateError.network("404")))
        } else {
            completion(manifest.map { .success($0) } ?? .failure(UpdateError.network("404")))
        }
    }

    func download(_ url: URL, to: URL, maxSize: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        requested.append(url.lastPathComponent)
        guard let a = archive else { return completion(.failure(UpdateError.network("404"))) }
        do { try? FileManager.default.removeItem(at: to); try FileManager.default.copyItem(at: a, to: to); completion(.success(())) }
        catch { completion(.failure(error)) }
    }
}

private func run(_ path: String, _ args: [String]) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
}

/// A real, ad-hoc signed bundle (`/usr/bin/true` as its executable), zipped like build-app.sh does.
private func makeRelease(in dir: URL, version: String, bundleID: String) -> URL {
    let stage = dir.appendingPathComponent("stage/SafeNet", isDirectory: true)
    let app = stage.appendingPathComponent("SafeNet.app")
    let macos = app.appendingPathComponent("Contents/MacOS")
    try? FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
    try? FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macos.appendingPathComponent("SafeNetApp").path)
    let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version,
                               "CFBundleExecutable": "SafeNetApp", "CFBundlePackageType": "APPL", "CFBundleName": "SafeNet"]
    (info as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
    run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
    let zip = dir.appendingPathComponent("SafeNet-\(version).zip")
    run("/usr/bin/ditto", ["-c", "-k", "--keepParent", stage.path, zip.path])
    return zip
}

private final class URig {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sn-updater-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let key = Curve25519.Signing.PrivateKey()
    let fetcher = FakeFetcher()
    let queue = DispatchQueue(label: "test.updater")
    var safe = true
    var plans: [UpdateInstaller.Plan] = []
    var updater: Updater!
    let bundleID = "local.safenet.test"

    init(mode: UpdateMode, current: String = "1.0.0", setupDisabled: String? = nil) {
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("Applications/SafeNet.app"), withIntermediateDirectories: true)
        let setup = UpdaterSetup(feed: URL(string: "https://example.invalid/latest/update.json"),
                                 publicKey: key.publicKey.rawRepresentation.base64EncodedString(),
                                 bundleURL: root.appendingPathComponent("Applications/SafeNet.app"), bundleID: bundleID,
                                 version: current, disabledReason: setupDisabled)
        updater = Updater(setup: setup, stateDir: root.appendingPathComponent("state", isDirectory: true), fetcher: fetcher,
                          queue: queue, mode: mode, safeToInstall: { [unowned self] done in done(self.safe) },
                          launchHelper: { [unowned self] p in self.plans.append(p); return true }, terminate: {})
    }

    /// Publishes `version` (signed manifest + archive); `corruptHash` breaks the archive check.
    func publish(_ version: String, corruptHash: Bool = false, signWith other: Curve25519.Signing.PrivateKey? = nil) {
        let zip = makeRelease(in: root.appendingPathComponent("rel-\(version)"), version: version, bundleID: bundleID)
        let size = (try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? 0
        let sha = corruptHash ? String(repeating: "0", count: 64) : (sha256Hex(file: zip) ?? "")
        let m = UpdateManifest(version: version, url: "https://example.invalid/download/SafeNet-\(version).zip", sha256: sha, size: size)
        let data = try! JSONEncoder().encode(m)
        fetcher.manifest = data
        fetcher.signature = try! (other ?? key).signature(for: data).base64EncodedString()
        fetcher.archive = zip
    }

    /// Lets every queued hop of the updater run (fetch callbacks, unpack, safety answer).
    func drain() { for _ in 0..<20 { queue.sync {} } }

    func check(user: Bool) { queue.sync { updater.check(userInitiated: user) }; drain() }
    var state: UpdateState { queue.sync { updater.state } }

    deinit { updater.stop(); try? FileManager.default.removeItem(at: root) }
}

func registerUpdaterTests() {
    test("testUpdaterAutoDownloadsVerifiesAndInstalls") {
        let r = URig(mode: .auto)
        r.publish("1.1.0")
        r.check(user: false)
        expectEqual(r.state, .installing("1.1.0"))
        expectEqual(r.plans.count, 1)
        guard let p = r.plans.first else { return }
        expectEqual(p.toVersion, "1.1.0"); expectEqual(p.fromVersion, "1.0.0")
        expectEqual(p.target.lastPathComponent, "SafeNet.app")
        expect(FileManager.default.fileExists(atPath: p.staged.appendingPathComponent("Contents/MacOS/SafeNetApp").path), "staged bundle")
        expectEqual(UpdateInstaller.Plan(arguments: p.arguments)?.arguments, p.arguments, "the helper can parse its arguments")
    }

    test("testUpdaterWaitsWhileProtectionIsEngaged") {
        let r = URig(mode: .auto)
        r.safe = false
        r.publish("1.1.0")
        r.check(user: false)
        expectEqual(r.state, .waiting("1.1.0"))
        expectEqual(r.plans.count, 0, "never quits while apps are frozen or paused")
        r.safe = true
        r.check(user: true)                                  // "Проверить сейчас" retries the install
        expectEqual(r.plans.count, 1)
    }

    test("testUpdaterNotifyModeOnlyTells") {
        let r = URig(mode: .notify)
        r.publish("1.1.0")
        r.check(user: false)
        expectEqual(r.state, .available("1.1.0"))
        expectEqual(r.fetcher.requested.filter { $0.hasSuffix(".zip") }, [], "nothing downloaded")
        r.updater.checkNow(); r.drain()
        expectEqual(r.state, .available("1.1.0"))
        r.updater.installAvailable(); r.drain()
        expectEqual(r.plans.count, 1)
    }

    test("testUpdaterUpToDate") {
        let r = URig(mode: .auto, current: "1.1.0")
        r.publish("1.1.0")
        r.check(user: false)
        guard case .upToDate = r.state else { return expect(false, "\(r.state)") }
        expectEqual(r.plans.count, 0)
    }

    test("testUpdaterRejectsForeignSignatureAndBadArchive") {
        let r = URig(mode: .auto)
        r.publish("1.1.0", signWith: Curve25519.Signing.PrivateKey())
        r.check(user: false)
        expectEqual(r.state, .failed(UpdateError.badSignature.description))
        expectEqual(r.fetcher.requested.filter { $0.hasSuffix(".zip") }, [], "a bad manifest never leads to a download")
        let r2 = URig(mode: .auto)
        r2.publish("1.1.0", corruptHash: true)
        r2.check(user: false)
        guard case .failed(let m) = r2.state else { return expect(false, "\(r2.state)") }
        expect(m.contains("контрольная сумма"), m)
        expectEqual(r.plans.count + r2.plans.count, 0)
    }

    test("testUpdaterDisabledDoesNothing") {
        let r = URig(mode: .auto, setupDisabled: "в этой сборке не задан ключ проверки обновлений")
        r.publish("1.1.0")
        r.check(user: true)
        guard case .disabled = r.state else { return expect(false, "\(r.state)") }
        expectEqual(r.fetcher.requested, [], "no network at all")
    }

    test("testUpdaterSetupFromBundle") {
        let s = UpdaterSetup.current(bundle: .main, environment: [:], testMode: false)
        expect(s.disabledReason != nil, "the test binary is not an .app")
        expect(UpdateText.status(.waiting("1.2.0")).contains("ничего не заморожено"))
        expectEqual(UpdateText.menuLine(.upToDate(Date())), nil)
        expectEqual(UpdateText.menuLine(.available("1.2.0")), "Доступна версия 1.2.0")
    }
}
