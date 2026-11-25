import Foundation
import SwiftUI
import AppKit
import Combine
import SafeNetCore

/// Single source of truth for the views. Main thread only: every update from the engine is
/// delivered on the main queue, and actions are forwarded to the engine's queue.
public final class AppState: ObservableObject {
    @Published public private(set) var status = EngineStatus()
    @Published public private(set) var config: Config
    @Published public private(set) var autostartEnabled = Autostart.isEnabled
    /// Read again on panel appear and app activation (approval happens in System Settings).
    @Published public private(set) var autostartState = Autostart.current
    /// Separate message channels, so one kind never wipes another:
    /// config load/save errors (cleared once a load or save succeeds again) ...
    @Published public private(set) var configError: String?
    /// ... informational notices from the engine (test mode refusing writes, broken-file copy) ...
    @Published public private(set) var notice: String?
    /// ... and the autostart result (set/cleared only by `setAutostart`).
    @Published public private(set) var autostartError: String?
    /// Apps shown in the menu window: selected ones plus ones toggled off during this session
    /// (so a row does not vanish under the mouse).
    @Published public private(set) var shownApps: [String] = []
    /// Last deep check ("Проверка" tab), kept while the app runs.
    @Published public internal(set) var lastDeepCheck: DeepCheckData?
    /// A deep check is in flight (kept here, not in the view: switching tabs must not allow a
    /// second run).
    @Published public private(set) var deepCheckRunning = false

    public let testMode: TestMode?
    /// Test mode without SAFENET_CONFIG_DIR: nothing is saved (shown in the window).
    public private(set) var configReadOnly = false
    public let appearance: SystemAppearance
    public let theme: Theme

    private let system: LiveSystem?
    private let previewLog: EventLog?
    private let notifier = Notifier()
    private var tracker = NoticeTracker()
    private var sessionApps: [String] = []
    private var activationObserver: NSObjectProtocol?

    // Brief interface (Task 9): convenience views of the status.
    public var state: GuardState { status.state }
    public var snapshot: NetSnapshot? { status.snapshot }
    public var lastIP: IPAnswer? { status.confirmed }

    /// Production instance: real engine (call `start()` once the app launched).
    public init(system: LiveSystem, appearance: SystemAppearance = SystemAppearance()) {
        self.system = system
        previewLog = nil
        self.testMode = system.testMode
        self.appearance = appearance
        config = system.engine.config
        Format.setTimeZone(system.engine.config.timezone)
        theme = Theme(config: system.engine.config, appearance: appearance)
        rebuildShownApps()
        system.onStatus = { [weak self] s in self?.receive(s) }
        system.onConfig = { [weak self] c in self?.receiveConfig(c) }
        system.onConfigError = { [weak self] e in self?.receiveConfigError(e) }
        system.onConfigHealthy = { [weak self] in self?.configHealthy() }
        system.onNotice = { [weak self] e in self?.receiveNotice(e) }
        configReadOnly = system.configReadOnly
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshAutostart()
        }
    }

    deinit { if let o = activationObserver { NotificationCenter.default.removeObserver(o) } }

    /// Static instance for previews / UI tests (no engine). `log` feeds the journal tab.
    public init(preview config: Config, status: EngineStatus, testMode: TestMode? = nil, systemScheme: ColorScheme = .dark,
                log: EventLog? = nil) {
        system = nil
        previewLog = log
        self.testMode = testMode
        appearance = SystemAppearance(provider: { systemScheme == .dark ? "Dark" : nil },
                                      changes: Empty<Void, Never>().eraseToAnyPublisher())
        self.config = config
        self.status = status
        theme = Theme(config: config, systemScheme: systemScheme)
        rebuildShownApps()
    }

    public func start() { system?.start() }
    public func shutdown() { system?.shutdown() }

    // MARK: Derived

    public var hasProtectedApps: Bool { !AppCatalog.appIDs(in: config).isEmpty }
    /// First run: selected apps would freeze forever because nothing is allowed.
    public var needsAllowSetup: Bool { Engine.needsAllowSetup(config) }

    public static let proxyWarningText = "Включён системный прокси: программы командной строки (например, Claude Code) его обходят и идут в сеть напрямую, а SafeNet видит IP прокси — используйте режим TUN / полного туннеля VPN."
    /// R4 (warn only): a system proxy is set, so SafeNet's own checks go through it while
    /// command-line tools ignore it.
    public static func proxyWarning(_ s: EngineStatus) -> String? { s.snapshot?.proxy != nil ? proxyWarningText : nil }
    public var proxyWarning: String? { AppState.proxyWarning(status) }
    /// Deep check is possible (false in previews: no engine).
    public var canDeepCheck: Bool { system != nil }

    // MARK: Actions (forwarded to the engine queue)

    public func toggleApp(_ id: String) {
        if !sessionApps.contains(id) { sessionApps.append(id) }
        system?.perform { $0.toggleApp(id) }
    }
    public func pause(for seconds: TimeInterval) { system?.perform { $0.guardian.pause(for: seconds) } }
    public func pauseUntilRestart() { system?.perform { $0.guardian.pauseUntilRestart() } }
    /// "Пауза" with the configured default length (`pause_default`).
    public func pause() { pause(for: defaultPause) }
    public var defaultPause: TimeInterval { config.pauseDefault }
    public func resumeProtection() { system?.perform { $0.guardian.resume() } }
    /// "Разрешить этот IP": the Guard offers the confirmed IP, the engine appends it to allow.ips.
    public func allowCurrent() { system?.perform { $0.guardian.allowCurrentIP() } }
    /// First-run: allow the country of the confirmed IP.
    public func allowCurrentCountry() { system?.perform { $0.allowCurrentCountry() } }
    public func extend(by seconds: TimeInterval = 60) { system?.perform { $0.guardian.extend(by: seconds) } }
    public func closeNow() { system?.perform { $0.guardian.closeNow() } }
    public func checkNow() { system?.perform { $0.checkNow() } }

    /// Every settings change goes through the engine (`Engine.updateConfig`): validation of the
    /// written file, test mode refusing writes and the broken-file copy all apply. Preview: in memory.
    public func update(_ mutate: @escaping (inout Config) -> Void) {
        if let s = system {
            s.perform { $0.updateConfig(mutate) }
        } else {
            var c = config; mutate(&c); receiveConfig(c)
        }
    }

    public func setAutostart(_ on: Bool) {
        do { try Autostart.set(on); autostartError = nil } catch { autostartError = "Автозапуск: \((error as? Autostart.Unavailable)?.description ?? Engine.safeDescription(error))" }
        refreshAutostart()
    }

    /// Re-reads the login-item status (the user may have approved it in System Settings).
    public func refreshAutostart() {
        guard system != nil else { return }
        let s = Autostart.current
        if s != autostartState { autostartState = s }
        let on = [.on, .requiresApproval].contains(s)
        if on != autostartEnabled { autostartEnabled = on }
    }

    public func openLoginItemsSettings() { Autostart.openLoginItemsSettings() }

    public func dismissNotice() { notice = nil }

    // MARK: Journal, deep check, files

    public var eventLog: EventLog? { system?.engine.log ?? previewLog }

    /// Runs the on-demand deep check off the main thread (ignored while one runs or without an
    /// engine); the result lands in `lastDeepCheck` on the main queue.
    public func runDeepCheck() {
        guard let s = system, !deepCheckRunning else { return }
        deepCheckRunning = true
        s.deepCheck { d in
            DispatchQueue.main.async { [weak self] in self?.lastDeepCheck = d; self?.deepCheckRunning = false }
        }
    }

    public var configURL: URL? { system?.paths.config }

    /// Shows config.yaml selected in Finder.
    public func revealConfig() {
        guard let u = configURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([u])
    }

    public static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "разработческая сборка"
    }

    /// Lines for the windows, in order: config error (red), autostart error (red), notice (neutral).
    public var messages: [(text: String, isError: Bool)] {
        var out: [(text: String, isError: Bool)] = []
        if let e = configError { out.append((e, true)) }
        if let e = autostartError { out.append((e, true)) }
        if let n = notice { out.append((n, false)) }
        return out
    }

    public func quit() { NSApp.terminate(nil) }

    // MARK: Updates (main thread)

    private func receive(_ s: EngineStatus) {
        let changed = s.state != status.state
        status = s
        if changed, let n = tracker.update(s.state) { notifier.post(n) }
    }

    /// A new config (hot reload, own change, or the in-memory one after a failed save). Clears no
    /// message: a failed save is followed by this very call.
    func receiveConfig(_ c: Config) {
        config = c
        Format.setTimeZone(c.timezone)
        theme.update(config: c)
        rebuildShownApps()
    }

    func receiveConfigError(_ e: String) {
        configError = e
        notifier.post(.configError(e))
    }

    /// config.yaml loaded or saved fine again.
    func configHealthy() { configError = nil }

    func receiveNotice(_ n: String) { notice = n }

    private func rebuildShownApps() {
        var out: [String] = []
        for id in config.apps + config.customApps.map({ $0.name }) + sessionApps where !out.contains(id) { out.append(id) }
        shownApps = out
    }
}
