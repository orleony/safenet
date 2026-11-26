import Foundation
import SafeNetCore

/// What the window shows about updates.
public enum UpdateState: Equatable {
    /// Updates cannot work in this build/run (bare binary, no key, test mode); the text says why.
    case disabled(String)
    case idle
    case checking
    case upToDate(Date)
    /// `updates: notify`: a verified newer version waits for the user's "Обновить".
    case available(String)
    case downloading(String)
    /// Downloaded and verified; installs as soon as nothing is frozen / paused.
    case waiting(String)
    case installing(String)
    case failed(String)
}

/// Network access of the updater (tests replace it).
public protocol UpdateFetcher {
    func data(_ url: URL, completion: @escaping (Result<Data, Error>) -> Void)
    /// Downloads to `to` (replaced); fails beyond `maxSize` bytes.
    func download(_ url: URL, to: URL, maxSize: Int, completion: @escaping (Result<Void, Error>) -> Void)
}

/// Where the updater looks and what it may replace, read from the running bundle.
public struct UpdaterSetup: Equatable {
    public var feed: URL?
    public var publicKey: String
    /// The installed .app (nil: bare binary, nothing to replace).
    public var bundleURL: URL?
    public var bundleID: String?
    public var version: String
    /// Non-nil: updates are off for this run, with the reason.
    public var disabledReason: String?

    public init(feed: URL?, publicKey: String, bundleURL: URL?, bundleID: String?, version: String, disabledReason: String? = nil) {
        self.feed = feed; self.publicKey = publicKey; self.bundleURL = bundleURL; self.bundleID = bundleID
        self.version = version; self.disabledReason = disabledReason
    }

    /// From Info.plist (`SafeNetUpdateFeed`, `SafeNetUpdatePublicKey`); `SAFENET_UPDATE_FEED` /
    /// `SAFENET_UPDATE_PUBKEY` override them (testing a release before publishing it).
    public static func current(bundle: Bundle = .main, environment env: [String: String], testMode: Bool) -> UpdaterSetup {
        let info = bundle.infoDictionary ?? [:]
        let feedText = env["SAFENET_UPDATE_FEED"].flatMap { $0.isEmpty ? nil : $0 } ?? (info["SafeNetUpdateFeed"] as? String) ?? ""
        let key = env["SAFENET_UPDATE_PUBKEY"].flatMap { $0.isEmpty ? nil : $0 } ?? (info["SafeNetUpdatePublicKey"] as? String) ?? ""
        let version = (info["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        let isApp = bundle.bundleURL.pathExtension == "app"
        var s = UpdaterSetup(feed: URL(string: feedText), publicKey: key, bundleURL: isApp ? bundle.bundleURL : nil,
                             bundleID: bundle.bundleIdentifier, version: version)
        if !isApp || s.bundleID == nil {
            s.disabledReason = "обновление работает только из SafeNet.app"
        } else if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || s.feed == nil {
            s.disabledReason = "в этой сборке не задан ключ проверки обновлений"
        } else if testMode && env["SAFENET_UPDATE_FEED"] == nil {
            s.disabledReason = "в тестовом режиме обновления не проверяются"
        } else if bundle.bundleURL.path.contains("/AppTranslocation/") {
            s.disabledReason = "macOS запустила SafeNet из временной копии: перенесите SafeNet.app в «Программы»"
        }
        return s
    }
}

/// Checks the release feed, downloads and verifies a newer build, and hands it to the install
/// helper (`--install-update`) once installing is safe: nothing frozen, closed or paused (the app
/// quits for a few seconds, and quitting resumes every frozen process). All work runs on one
/// serial queue; `onState` and `notify` are called on the main queue.
public final class Updater {
    private let setup: UpdaterSetup
    private let markers: UpdateMarkers
    private let fetcher: UpdateFetcher
    private let queue: DispatchQueue
    /// `updates` from the config (queue-confined; set through `setMode`).
    private var mode: UpdateMode
    private let safeToInstall: (@escaping (Bool) -> Void) -> Void
    private let launchHelper: (UpdateInstaller.Plan) -> Bool
    private let terminate: () -> Void
    private let now: () -> Date

    public var onState: ((UpdateState) -> Void)?
    public var notify: ((NoticeText) -> Void)?

    private(set) var state: UpdateState = .idle
    private var lastCheck: Date?
    private var notifiedVersion: String?
    /// Downloaded and verified, waiting to be installed.
    private var ready: (manifest: UpdateManifest, app: URL)?
    private var timer: DispatchSourceTimer?
    private var waitTimer: DispatchSourceTimer?
    private var explicitInstall = false
    private var busy = false

    /// Automatic checks: the first `firstDelay` after start, then whenever the last one is older
    /// than `interval` (looked at every `tick`; wall clock, so sleep does not postpone it).
    var firstDelay: TimeInterval = 60
    var interval: TimeInterval = 24 * 3600
    var tick: TimeInterval = 3600
    var waitRetry: TimeInterval = 30

    public init(setup: UpdaterSetup, stateDir: URL, fetcher: UpdateFetcher = URLSessionUpdateFetcher(),
                queue: DispatchQueue = DispatchQueue(label: "safenet.updater"),
                mode: UpdateMode,
                safeToInstall: @escaping (@escaping (Bool) -> Void) -> Void,
                launchHelper: @escaping (UpdateInstaller.Plan) -> Bool = Updater.spawnHelper,
                terminate: @escaping () -> Void,
                now: @escaping () -> Date = Date.init) {
        self.setup = setup; self.markers = UpdateMarkers(dir: stateDir); self.fetcher = fetcher; self.queue = queue
        self.mode = mode; self.safeToInstall = safeToInstall; self.launchHelper = launchHelper
        self.terminate = terminate; self.now = now
        if let why = setup.disabledReason { state = .disabled(why) }
    }

    public var isEnabled: Bool { setup.disabledReason == nil }

    /// Starts the automatic checks (only when updates are possible at all).
    public func start() {
        publish(state)
        guard isEnabled else { return }
        queue.async { self.cleanStaleStaging() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + firstDelay, repeating: tick)
        t.setEventHandler { [weak self] in self?.automaticTick() }
        t.resume()
        timer = t
    }

    /// The config changed (`updates`).
    public func setMode(_ m: UpdateMode) { queue.async { self.mode = m } }

    public func stop() { timer?.cancel(); timer = nil; waitTimer?.cancel(); waitTimer = nil }

    /// "Проверить обновления": checks at once, whatever `updates` says; a newer version is
    /// shown for confirmation before download.
    public func checkNow() { queue.async { self.check(userInitiated: false, onlyReport: true) } }

    /// "Обновить" for a version announced in notify mode.
    public func installAvailable() { queue.async { self.check(userInitiated: true) } }

    // MARK: Internals (queue)

    private func automaticTick() {
        if ready != nil { return attemptInstall() }
        guard mode != .off, !busy else { return }
        if let l = lastCheck, now().timeIntervalSince(l) < interval { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool, onlyReport: Bool = false) {
        guard isEnabled, let feed = setup.feed, !busy else { return }
        if ready != nil { return attemptInstall() }
        busy = true
        publish(.checking)
        let sigURL = URL(string: feed.absoluteString + ".sig")!
        fetcher.data(feed) { [weak self] m in
            self?.queue.async {
                guard let self = self else { return }
                switch m {
                case .failure(let e): self.fail(.network(Updater.describe(e)))
                case .success(let manifest):
                    self.fetcher.data(sigURL) { s in
                        self.queue.async {
                            switch s {
                            case .failure(let e): self.fail(.network(Updater.describe(e)))
                            case .success(let sig): self.decide(manifest, String(decoding: sig, as: UTF8.self), userInitiated, onlyReport)
                            }
                        }
                    }
                }
            }
        }
    }

    private func decide(_ data: Data, _ sig: String, _ userInitiated: Bool, _ onlyReport: Bool) {
        lastCheck = now()
        guard let current = AppVersion(setup.version) else { return fail(.install("версия приложения не читается")) }
        let found: UpdateManifest?
        do {
            found = try UpdateDecision.evaluate(manifest: data, signature: sig, publicKey: setup.publicKey,
                                                current: current, system: UpdateDecision.systemVersion)
        } catch let e as UpdateError { return fail(e) } catch { return fail(.badManifest("\(error)")) }
        guard let m = found else {
            busy = false
            publish(.upToDate(now()))
            return
        }
        if !onlyReport && (userInitiated || mode == .auto) {
            explicitInstall = userInitiated
            download(m)
        } else {
            busy = false
            publish(.available(m.version))
            if notifiedVersion != m.version {
                notifiedVersion = m.version
                announce(NoticeText(title: "SafeNet", body: "Доступна версия \(m.version). Обновить можно в меню SafeNet."))
            }
        }
    }

    private func download(_ m: UpdateManifest) {
        guard let url = m.downloadURL else { return fail(.badManifest("адрес архива")) }
        publish(.downloading(m.version))
        let dir = markers.staging.appendingPathComponent(m.version, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            return fail(.install("не создать папку для загрузки"))
        }
        let zip = dir.appendingPathComponent("SafeNet.zip")
        fetcher.download(url, to: zip, maxSize: m.size) { [weak self] r in
            self?.queue.async {
                guard let self = self else { return }
                switch r {
                case .failure(let e): self.fail(.network(Updater.describe(e)))
                case .success: self.unpack(m, zip: zip, dir: dir)
                }
            }
        }
    }

    private func unpack(_ m: UpdateManifest, zip: URL, dir: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? -1
        guard size == m.size else { return fail(.badArchive("размер \(size) вместо \(m.size)")) }
        guard sha256Hex(file: zip) == m.sha256 else { return fail(.badArchive("контрольная сумма не совпадает")) }
        let out = dir.appendingPathComponent("unpacked", isDirectory: true)
        let runner = ProcessCommandRunner()
        guard runner.run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path], timeout: 120) != nil else {
            return fail(.badArchive("не распаковывается"))
        }
        let name = setup.bundleURL?.lastPathComponent ?? "SafeNet.app"
        guard let found = Updater.findApp(named: name, in: out) else { return fail(.badArchive("в архиве нет \(name)")) }
        let app = dir.appendingPathComponent(name)
        do { try FileManager.default.moveItem(at: found, to: app) } catch { return fail(.badArchive("не удалось подготовить")) }
        try? FileManager.default.removeItem(at: out)
        try? FileManager.default.removeItem(at: zip)
        _ = runner.run("/usr/bin/xattr", ["-cr", app.path], timeout: 30)
        if let why = RealInstallerSystem.validateBundle(app, bundleID: setup.bundleID ?? "", version: m.version, runner: runner) {
            return fail(.badArchive(why))
        }
        ready = (m, app)
        busy = false
        attemptInstall()
    }

    private func attemptInstall() {
        guard let r = ready else { return }
        safeToInstall { [weak self] ok in
            self?.queue.async {
                guard let self = self, let r2 = self.ready, r2.app == r.app else { return }
                if !self.explicitInstall && self.mode != .auto {
                    self.waitTimer?.cancel()
                    self.waitTimer = nil
                    self.ready = nil
                    self.publish(self.mode == .off ? .idle : .available(r2.manifest.version))
                    return
                }
                if ok { self.install(r2.manifest, r2.app) } else { self.waitForSafety(r2.manifest) }
            }
        }
    }

    private func waitForSafety(_ m: UpdateManifest) {
        publish(.waiting(m.version))
        guard waitTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + waitRetry, repeating: waitRetry)
        t.setEventHandler { [weak self] in self?.attemptInstall() }
        t.resume()
        waitTimer = t
    }

    private func install(_ m: UpdateManifest, _ app: URL) {
        waitTimer?.cancel(); waitTimer = nil
        guard let target = setup.bundleURL, let id = setup.bundleID else { return fail(.notConfigured) }
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            ready = nil
            return fail(.install("нет прав на запись в папку \(target.deletingLastPathComponent().lastPathComponent)"))
        }
        let plan = UpdateInstaller.Plan(parentPID: getpid(), staged: app, target: target, stateDir: markers.dir,
                                        bundleID: id, fromVersion: setup.version, toVersion: m.version)
        publish(.installing(m.version))
        guard launchHelper(plan) else {
            ready = nil
            return fail(.install("не запустился помощник установки"))
        }
        ready = nil
        DispatchQueue.main.async { self.terminate() }
    }

    private func fail(_ e: UpdateError) {
        busy = false
        publish(.failed(e.description))
    }

    private func publish(_ s: UpdateState) {
        state = s
        let cb = onState
        DispatchQueue.main.async { cb?(s) }
    }

    private func announce(_ n: NoticeText) {
        let cb = notify
        DispatchQueue.main.async { cb?(n) }
    }

    /// Leftovers of an interrupted download (never the one being installed: this runs at start).
    private func cleanStaleStaging() {
        try? FileManager.default.removeItem(at: markers.staging)
    }

    // MARK: Helpers

    static func findApp(named name: String, in dir: URL) -> URL? {
        let direct = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        let subs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for s in subs.sorted(by: { $0.path < $1.path }) where s.pathExtension != "app" {
            let c = s.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: c.path) { return c }
        }
        return nil
    }

    static func describe(_ e: Error) -> String {
        if let u = e as? UpdateError { return u.description }
        let n = e as NSError
        if n.domain == NSURLErrorDomain { return "ошибка сети \(n.code)" }
        return "ошибка \(n.domain) \(n.code)"
    }

    /// The current executable in helper mode, detached from our lifetime (it waits for us to exit).
    public static func spawnHelper(_ plan: UpdateInstaller.Plan) -> Bool {
        guard let exe = Bundle.main.executableURL else { return false }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--install-update"] + plan.arguments
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); return true } catch { return false }
    }
}

/// URLSession without cookies, cache or credentials; manifest requests time out after 20 s.
public final class URLSessionUpdateFetcher: UpdateFetcher {
    private let session: URLSession

    public init() {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 600
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.httpCookieStorage = nil
        c.urlCredentialStorage = nil
        c.httpAdditionalHeaders = ["User-Agent": "SafeNet-Updater"]
        session = URLSession(configuration: c)
    }

    public func data(_ url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        session.dataTask(with: url) { d, r, e in
            if let e = e { return completion(.failure(e)) }
            guard let h = r as? HTTPURLResponse, h.statusCode == 200, let d = d else {
                return completion(.failure(UpdateError.network("ответ \((r as? HTTPURLResponse)?.statusCode ?? 0)")))
            }
            completion(.success(d))
        }.resume()
    }

    public func download(_ url: URL, to: URL, maxSize: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        session.downloadTask(with: url) { tmp, r, e in
            if let e = e { return completion(.failure(e)) }
            guard let h = r as? HTTPURLResponse, h.statusCode == 200, let tmp = tmp else {
                return completion(.failure(UpdateError.network("ответ \((r as? HTTPURLResponse)?.statusCode ?? 0)")))
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0
            guard size <= maxSize else { return completion(.failure(UpdateError.badArchive("больше заявленного размера"))) }
            do {
                try? FileManager.default.removeItem(at: to)
                try FileManager.default.moveItem(at: tmp, to: to)
                completion(.success(()))
            } catch { completion(.failure(error)) }
        }.resume()
    }
}
