import SwiftUI
import AppKit
import SafeNetCore

/// Owns the app-lifetime objects (AppState with its engine, SystemAppearance, Theme).
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppState?
    private var outsideClickMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Menu-bar agent: no Dock icon (works for the bare binary and the .app with LSUIElement).
        NSApp.setActivationPolicy(.accessory)
        AppDelegate.model?.theme.applyAppAppearance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.model?.start()
        // A menu-bar agent is never active, so a click on the desktop / another app does not make
        // the MenuBarExtra window resign key. Close it on any click outside SafeNet ourselves.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            for w in NSApp.windows where w.isVisible && String(describing: type(of: w)).contains("MenuBarExtra") {
                w.orderOut(nil)
            }
        }
        // SwiftUI may open the first Window scene at launch; the panel opens only on request.
        for w in NSApp.windows where w.identifier?.rawValue.hasPrefix("panel") == true { w.close() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.model?.shutdown()                // resumes every frozen process
    }
}

/// The SwiftUI app: `MenuBarExtra` (window style) + the panel window (`PanelView`). Closing the
/// panel never quits the app (`applicationShouldTerminateAfterLastWindowClosed` is false).
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
            PanelView(model: model)
                .environmentObject(theme)
                .preferredColorScheme(theme.forcedScheme)
        }
        .defaultSize(width: 760, height: 520)
        .windowResizability(.contentMinSize)
    }
}

/// Menu bar title per `config.menubar`: "🇳🇱 185.12.40.7", "🇳🇱 NL" or a state symbol. The
/// symbol is also shown next to the text whenever protection is not plainly "ok".
struct MenuBarLabel: View {
    @ObservedObject var model: AppState
    var body: some View { labelContent }

    @ViewBuilder private var labelContent: some View {
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
