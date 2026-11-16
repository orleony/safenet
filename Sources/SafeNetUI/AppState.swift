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
    /// Last config / autostart error shown in the window (nil = none).
    @Published public private(set) var lastError: String?
    /// Apps shown in the menu window: selected ones plus ones toggled off during this session
    /// (so a row does not vanish under the mouse).
    @Published public private(set) var shownApps: [String] = []

    public let testMode: TestMode?
    public let appearance: SystemAppearance
    public let theme: Theme

    private let system: LiveSystem?
    private let notifier = Notifier()
    private var tracker = NoticeTracker()
    private var sessionApps: [String] = []

    // Brief interface (Task 9): convenience views of the status.
    public var state: GuardState { status.state }
    public var snapshot: NetSnapshot? { status.snapshot }
    public var lastIP: IPAnswer? { status.confirmed }

    /// Production instance: real engine (call `start()` once the app launched).
    public init(system: LiveSystem, appearance: SystemAppearance = SystemAppearance()) {
        self.system = system
        self.testMode = system.testMode
        self.appearance = appearance
        config = system.engine.config
        theme = Theme(config: system.engine.config, appearance: appearance)
        rebuildShownApps()
        system.onStatus = { [weak self] s in self?.receive(s) }
        system.onConfig = { [weak self] c in self?.receive(c) }
        system.onConfigError = { [weak self] e in self?.reportConfigError(e) }
    }

    /// Static instance for previews / UI tests (no engine).
    public init(preview config: Config, status: EngineStatus, testMode: TestMode? = nil, systemScheme: ColorScheme = .dark) {
        system = nil
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

    // MARK: Actions (forwarded to the engine queue)

    public func toggleApp(_ id: String) {
        if !sessionApps.contains(id) { sessionApps.append(id) }
        system?.perform { $0.toggleApp(id) }
    }
    public func pause(for seconds: TimeInterval = 15 * 60) { system?.perform { $0.guardian.pause(for: seconds) } }
    public func pause() { pause(for: 15 * 60) }
    public func resumeProtection() { system?.perform { $0.guardian.resume() } }
    /// "Разрешить этот IP": the Guard offers the confirmed IP, the engine appends it to allow.ips.
    public func allowCurrent() { system?.perform { $0.guardian.allowCurrentIP() } }
    /// First-run: allow the country of the confirmed IP.
    public func allowCurrentCountry() { system?.perform { $0.allowCurrentCountry() } }
    public func extend(by seconds: TimeInterval = 60) { system?.perform { $0.guardian.extend(by: seconds) } }
    public func closeNow() { system?.perform { $0.guardian.closeNow() } }
    public func checkNow() { system?.perform { $0.checkNow() } }

    public func setAutostart(_ on: Bool) {
        do { try Autostart.set(on); lastError = nil } catch { lastError = "Автозапуск: \(error)" }
        autostartEnabled = Autostart.isEnabled
    }

    public func quit() { NSApp.terminate(nil) }

    // MARK: Updates (main thread)

    private func receive(_ s: EngineStatus) {
        let changed = s.state != status.state
        status = s
        if changed, let n = tracker.update(s.state) { notifier.post(n) }
    }

    private func receive(_ c: Config) {
        config = c
        theme.update(config: c)
        lastError = nil
        rebuildShownApps()
    }

    private func reportConfigError(_ e: String) {
        lastError = "Ошибка config.yaml: \(e). Работаю на прежних настройках."
        notifier.post(.configError(e))
    }

    private func rebuildShownApps() {
        var out: [String] = []
        for id in config.apps + config.customApps.map({ $0.name }) + sessionApps where !out.contains(id) { out.append(id) }
        shownApps = out
    }
}
