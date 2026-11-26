import Foundation
import SafeNetCore

/// Built-in VPN, app side (main thread): the server list (vpn.json), the root helper's state and
/// the connect / disconnect actions. Reports the tunnel to the engine (`onTunnel`): while the VPN
/// is switched on and its tunnel is not running, the protected apps freeze.
public final class VPNController: ObservableObject {
    public enum Helper: Equatable {
        case unknown
        case notInstalled
        /// Installed but from another SafeNet / sing-box version: reinstalled on connect.
        case outdated(VPNHelperStatus)
        case ready(VPNHelperStatus)
    }

    @Published public private(set) var settings: VPNSettings
    @Published public private(set) var helper: Helper = .unknown
    /// Something in progress ("Подключение…"); nil = idle.
    @Published public private(set) var busy: String?
    /// Last error or note for the VPN tab.
    @Published public private(set) var message: String?

    /// (switched on, tunnel running) -> engine.
    var onTunnel: ((Bool, Bool) -> Void)?
    /// Path fragments / names of the protected apps (for `.apps` mode).
    var protectedApps: () -> (paths: [String], names: [String]) = { ([], []) }

    private let store: VPNStore?
    /// Where the downloaded sing-box is kept (the app's support directory).
    private let cacheDir: URL
    private let work = DispatchQueue(label: "safenet.vpn.controller")
    private var timer: Timer?
    private var lastReported: (Bool, Bool)?
    private let bundledSingBox = VPNInstaller.bundledSingBoxVersion()

    public init(store: VPNStore?, cacheDir: URL) {
        self.store = store
        self.cacheDir = cacheDir
        settings = store?.load() ?? VPNSettings()
    }

    /// Preview / tests.
    public init(preview: VPNSettings, helper: Helper) {
        store = nil; settings = preview; self.helper = helper
        cacheDir = FileManager.default.temporaryDirectory
    }

    public var isRunning: Bool { if case .ready(let s) = helper { return s.state == .running }; return false }
    public var helperStatus: VPNHelperStatus? {
        switch helper { case .ready(let s), .outdated(let s): return s; default: return nil }
    }
    public var canConnect: Bool { settings.selectedProfile != nil && busy == nil && !coreMissing }
    /// A dev build (not an .app) cannot install the root helper.
    public var coreMissing: Bool { store != nil && VPNInstaller.appExecutable() == nil }

    public func start() {
        guard store != nil else { return }
        poll { [weak self] in
            guard let self = self, self.settings.enabled else { return }
            if !self.isRunning { self.connect(install: false) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        refreshAllSubscriptions(silently: true)
        Timer.scheduledTimer(withTimeInterval: 12 * 3600, repeats: true) { [weak self] _ in
            self?.refreshAllSubscriptions(silently: true)
        }
    }

    // MARK: Helper state

    func poll(then: (() -> Void)? = nil) {
        let bundled = bundledSingBox
        work.async { [weak self] in
            let r = VPNHelperClient.status()
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch r {
                case .success(let s): self.helper = VPNInstaller.isCurrent(s, bundledSingBox: bundled) ? .ready(s) : .outdated(s)
                case .failure(.notInstalled): self.helper = .notInstalled
                case .failure: break                          // busy / timeout: keep the last state
                }
                self.report()
                then?()
            }
        }
    }

    private func report() {
        let now = (settings.enabled, helperStatus?.state == .running)
        guard lastReported.map({ $0 != now }) ?? true else { return }
        lastReported = now
        onTunnel?(now.0, now.1)
    }

    // MARK: Servers

    /// Adds what the user pasted: a subscription URL (https://…) or one or more server links.
    public func add(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        message = nil
        if t.lowercased().hasPrefix("https://") || t.lowercased().hasPrefix("http://") {
            guard let url = URL(string: t) else { message = "Ссылка подписки повреждена"; return }
            var src = VPNSource(kind: .subscription, url: url.absoluteString, links: [])
            busy = "Загрузка подписки…"
            fetch(url) { [weak self] result in
                guard let self = self else { return }
                self.busy = nil
                switch result {
                case .success(let c):
                    src.links = c.profiles.map { $0.link }; src.title = c.title; src.info = c.info; src.updated = Date()
                    self.mutate { $0.sources.append(src); $0.fixSelection() }
                    self.message = "Добавлено серверов: \(c.profiles.count)" + (c.skipped.isEmpty ? "" : ", пропущено: \(c.skipped.count)")
                case .failure(let e): self.message = "Подписка: \(e)"
                }
            }
            return
        }
        var added = 0, errors: [String] = []
        var newSources: [VPNSource] = []
        for line in t.split(whereSeparator: { $0.isNewline }).map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            do {
                let p = try ProxyLink.parse(line)
                newSources.append(VPNSource(kind: .link, links: [p.link], title: p.name))
                added += 1
            } catch { errors.append("\(error)") }
        }
        if added > 0 { mutate { $0.sources += newSources; $0.fixSelection() } }
        message = added > 0 ? "Добавлено серверов: \(added)" + (errors.isEmpty ? "" : "; ошибка: \(errors[0])")
                            : (errors.first.map { "Не удалось добавить: \($0)" } ?? "Нет ссылок")
    }

    public func remove(_ sourceID: String) {
        let wasSelected = settings.selectedProfile.map { p in settings.sources.first { $0.id == sourceID }?.links.contains(p.link) ?? false } ?? false
        mutate { $0.sources.removeAll { $0.id == sourceID }; $0.fixSelection() }
        if wasSelected && settings.enabled { reconnect() }
    }

    public func select(_ profileID: String) {
        guard profileID != settings.selected else { return }
        mutate { $0.selected = profileID }
        if settings.enabled { reconnect() }
    }

    public func setMode(_ m: VPNMode) {
        guard m != settings.mode else { return }
        mutate { $0.mode = m }
        if settings.enabled { reconnect() }
    }

    /// Protected apps changed: in `.apps` mode the tunnel rules follow.
    public func protectedAppsChanged() {
        if settings.enabled && settings.mode == .apps && isRunning { reconnect() }
    }

    public func refresh(_ sourceID: String) {
        guard let src = settings.sources.first(where: { $0.id == sourceID }), src.kind == .subscription,
              let url = src.url.flatMap(URL.init(string:)) else { return }
        busy = "Обновление подписки…"
        fetch(url) { [weak self] r in
            guard let self = self else { return }
            self.busy = nil
            self.apply(r, to: sourceID, silently: false)
        }
    }

    private func refreshAllSubscriptions(silently: Bool) {
        for src in settings.sources where src.kind == .subscription {
            guard let url = src.url.flatMap(URL.init(string:)) else { continue }
            if let u = src.updated, Date().timeIntervalSince(u) < 6 * 3600, silently { continue }
            fetch(url) { [weak self] r in self?.apply(r, to: src.id, silently: silently) }
        }
    }

    private func apply(_ r: Result<SubscriptionContent, ProxyLinkError>, to id: String, silently: Bool) {
        switch r {
        case .success(let c):
            let before = settings.selectedProfile?.link
            mutate { s in
                guard let i = s.sources.firstIndex(where: { $0.id == id }) else { return }
                s.sources[i].links = c.profiles.map { $0.link }
                s.sources[i].title = c.title ?? s.sources[i].title
                s.sources[i].info = c.info
                s.sources[i].updated = Date()
                s.fixSelection()
            }
            if !silently { message = "Подписка обновлена: серверов \(c.profiles.count)" }
            if settings.enabled, settings.selectedProfile?.link != before { reconnect() }
        case .failure(let e):
            if !silently { message = "Подписка: \(e)" }
        }
    }

    private func fetch(_ url: URL, done: @escaping (Result<SubscriptionContent, ProxyLinkError>) -> Void) {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        // Panels pick the answer format by User-Agent: ask for the plain link list.
        req.setValue("v2rayN/7.0 SafeNet", forHTTPHeaderField: "User-Agent")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        URLSession(configuration: cfg).dataTask(with: req) { data, resp, err in
            let r: Result<SubscriptionContent, ProxyLinkError>
            if let err = err {
                r = .failure(ProxyLinkError("не загрузилась: \(err.localizedDescription)"))
            } else if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                r = .failure(ProxyLinkError("сервер ответил HTTP \(http.statusCode)"))
            } else if let d = data, d.count <= 2_000_000 {
                let http = resp as? HTTPURLResponse
                do {
                    r = .success(try Subscription.decode(d, titleHeader: http?.value(forHTTPHeaderField: "profile-title"),
                                                         userinfoHeader: http?.value(forHTTPHeaderField: "subscription-userinfo")))
                } catch let e as ProxyLinkError { r = .failure(e) } catch { r = .failure(ProxyLinkError("\(error)")) }
            } else {
                r = .failure(ProxyLinkError("пустой или слишком большой ответ"))
            }
            DispatchQueue.main.async { done(r) }
        }.resume()
    }

    // MARK: Connect

    /// Switches the VPN on. `install`: install / update the helper if needed (password dialog).
    public func connect(install: Bool = true) {
        guard busy == nil else { return }
        guard let profile = settings.selectedProfile else { message = "Сначала добавьте сервер"; return }
        mutate { $0.enabled = true }
        report()
        let needsInstall: Bool
        switch helper { case .ready: needsInstall = false; default: needsInstall = true }
        if needsInstall && !install {
            message = "VPN включён, но системный помощник не установлен: нажмите «Подключить»."
            return
        }
        busy = needsInstall ? "Установка помощника (ядро VPN ~30 МБ скачивается один раз)…" : "Подключение…"
        message = nil
        let req = request(for: profile)
        let cache = cacheDir
        work.async { [weak self] in
            if needsInstall {
                if let e = VPNInstaller.install(cacheDir: cache) {
                    DispatchQueue.main.async {
                        self?.busy = nil
                        self?.message = e == "отменено" ? "Установка отменена — VPN не подключён." : "Помощник не установлен: \(e)"
                        self?.poll()
                    }
                    return
                }
                // The daemon needs a moment to open its socket.
                for _ in 0..<40 { if case .success = VPNHelperClient.status() { break }; usleep(250_000) }
                DispatchQueue.main.async { self?.busy = "Подключение…" }
            }
            let r = VPNHelperClient.start(req)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = nil
                switch r {
                case .success(let s):
                    if s.state != .running { self.message = s.message ?? "VPN не запустился" }
                case .failure(.refused(let m)): self.message = "Не подключено: \(m)"
                case .failure(.notInstalled): self.message = "Помощник не отвечает"
                case .failure(let e): self.message = "Не подключено: \(e)"
                }
                self.poll()
            }
        }
    }

    private func reconnect() {
        guard busy == nil, case .ready = helper else { return }
        connect(install: false)
    }

    public func disconnect() {
        mutate { $0.enabled = false }
        report()
        busy = "Отключение…"
        work.async { [weak self] in
            _ = VPNHelperClient.stop()
            DispatchQueue.main.async { self?.busy = nil; self?.poll() }
        }
    }

    /// Stops the VPN and removes the helper (password dialog).
    public func removeHelper() {
        mutate { $0.enabled = false }
        report()
        busy = "Удаление помощника…"
        work.async { [weak self] in
            _ = VPNHelperClient.stop()
            let e = VPNInstaller.uninstall()
            DispatchQueue.main.async {
                self?.busy = nil
                self?.message = e.map { $0 == "отменено" ? "Удаление отменено." : "Не удалось удалить: \($0)" } ?? "Помощник удалён."
                self?.poll()
            }
        }
    }

    func request(for p: VPNProfile) -> VPNStartRequest {
        let apps = protectedApps()
        return VPNStartRequest(outbound: p.outbound, mode: settings.mode, appPaths: apps.paths, appNames: apps.names)
    }

    private func mutate(_ f: (inout VPNSettings) -> Void) {
        var s = settings
        f(&s)
        guard s != settings else { return }
        settings = s
        store?.save(s)
    }
}
