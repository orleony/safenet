import SwiftUI
import AppKit
import SafeNetCore

/// Owns the app-lifetime objects (AppState with its engine, SystemAppearance, Theme).
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppState?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Menu-bar agent: no Dock icon (works for the bare binary and the .app with LSUIElement).
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.model?.start()
        // SwiftUI may open the first Window scene at launch; the panel opens only on request.
        for w in NSApp.windows where w.identifier?.rawValue.hasPrefix("panel") == true { w.close() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.model?.shutdown()                // resumes every frozen process
    }
}

/// The SwiftUI app: `MenuBarExtra` (window style) + the panel window (placeholder until Task 10).
public struct SafeNetMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppState
    @StateObject private var appearance: SystemAppearance
    @StateObject private var theme: Theme

    public init() {
        let m = AppDelegate.model ?? AppState(system: LiveSystem())
        AppDelegate.model = m
        _model = StateObject(wrappedValue: m)
        _appearance = StateObject(wrappedValue: m.appearance)
        _theme = StateObject(wrappedValue: m.theme)
    }

    public var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
                .environmentObject(theme)
                .preferredColorScheme(theme.forcedScheme)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("SafeNet", id: "panel") {
            PanelPlaceholderView(model: model)
                .environmentObject(theme)
                .preferredColorScheme(theme.forcedScheme)
        }
        .defaultSize(width: 720, height: 480)
    }
}

/// Menu bar title per `config.menubar`: "🇳🇱 185.12.40.7", "🇳🇱 NL" or a state symbol. The
/// symbol is also shown next to the text whenever protection is not plainly "ok".
struct MenuBarLabel: View {
    @ObservedObject var model: AppState

    var body: some View {
        let symbol = Format.stateSymbol(model.state)
        if let t = Format.menuTitle(model.config.menubar, confirmed: model.lastIP) {
            if case .ok = model.state {
                Text(t)
            } else {
                HStack(spacing: 3) { Image(systemName: symbol); Text(t) }
            }
        } else {
            Image(systemName: symbol)
        }
    }
}

/// Placeholder panel (Task 10 fills the tabs).
struct PanelPlaceholderView: View {
    @ObservedObject var model: AppState
    @EnvironmentObject var theme: Theme

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.spacing) {
            Text("SafeNet").font(theme.font(22, weight: .bold)).foregroundColor(p.text.swiftUIColor)
            Text(Format.stateTitle(model.state, hasApps: model.hasProtectedApps))
                .font(theme.font(14)).foregroundColor(p.muted.swiftUIColor)
            Text("Вкладки панели появятся позже. Настройки сейчас — в config.yaml.")
                .font(theme.font(12)).foregroundColor(p.muted.swiftUIColor)
            Spacer()
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 360, alignment: .topLeading)
        .background(p.background.swiftUIColor)
    }
}
