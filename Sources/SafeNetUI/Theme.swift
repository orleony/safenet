import SwiftUI
import AppKit
import SafeNetCore
import Combine

/// Corner radii and other fixed design constants.
public enum Metrics {
    /// Cards and grouped blocks.
    public static let cornerRadius: CGFloat = 14
    /// Text fields, list rows, sidebar items.
    public static let smallCornerRadius: CGFloat = 9
    public static let hairlineWidth: CGFloat = 1
    /// Fills of the translucent ("glass") controls, as opacity of the ink colour.
    public static let neutralFill: Double = 0.075
    public static let accentFill: Double = 0.22
    public static let tintStroke: Double = 0.16
}

/// Live theme resolved from Config and the current system colour scheme.
public final class Theme: ObservableObject {
    @Published public private(set) var palette: Palette
    @Published public private(set) var spacing: CGFloat
    @Published public private(set) var fontStyle: FontStyle
    private var config: Config
    private var systemScheme: ColorScheme

    private var appearanceSub: AnyCancellable?

    /// Fixed system scheme (tests, previews).
    public init(config: Config = .default, systemScheme: ColorScheme) {
        self.config = config; self.systemScheme = systemScheme
        palette = SafeNetUI.palette(theme: config.theme, system: systemScheme, accent: AccentName(configValue: config.accent))
        spacing = scaledSpacing(config.density)
        fontStyle = config.fontStyle
    }

    /// Live theme: starts from the real system scheme and follows later changes (no restart needed).
    public convenience init(config: Config = .default, appearance: SystemAppearance) {
        self.init(config: config, systemScheme: appearance.scheme)
        appearanceSub = appearance.$scheme.dropFirst().sink { [weak self] in self?.update(systemScheme: $0) }
    }

    /// Scheme to force on the app, nil for "as system". Apply `.preferredColorScheme(theme.forcedScheme)`
    /// on the outermost scene/root view of every window. This is safe because the system scheme comes
    /// from SystemAppearance, not from the SwiftUI environment.
    public var forcedScheme: ColorScheme? {
        switch config.theme {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    /// `NSApp.appearance` for a theme choice: nil follows the system. Needed besides
    /// `.preferredColorScheme`: on macOS 13/14 `.preferredColorScheme(nil)` does not reset an
    /// appearance SwiftUI already forced on a window, so "как в системе" would stick.
    public static func appearanceName(for t: ThemeChoice) -> NSAppearance.Name? {
        switch t {
        case .light: return .aqua
        case .dark: return .darkAqua
        case .system: return nil
        }
    }

    /// Sets the app-wide appearance (main thread; no-op before NSApplication exists, e.g. tests).
    public func applyAppAppearance() {
        guard let app = NSApp as NSApplication? else { return }
        app.appearance = Theme.appearanceName(for: config.theme).flatMap { NSAppearance(named: $0) }
    }

    public func update(config: Config) {
        let changed = config.theme != self.config.theme
        self.config = config; resolve()
        if changed { applyAppAppearance() }
    }
    public func update(systemScheme: ColorScheme) {
        guard systemScheme != self.systemScheme else { return }
        self.systemScheme = systemScheme; resolve()
    }

    private func resolve() {
        palette = SafeNetUI.palette(theme: config.theme, system: systemScheme, accent: AccentName(configValue: config.accent))
        spacing = scaledSpacing(config.density)
        fontStyle = config.fontStyle
    }

    /// Density-derived spacing: `spacing` (8 compact / 12 comfortable) is the main gap; these
    /// keep the menu window and the panel in proportion when density changes.
    public var smallGap: CGFloat { (spacing / 2).rounded() }        // 4 / 6
    public var padding: CGFloat { spacing + 2 }                       // 10 / 14
    public var rowPadding: CGFloat { (spacing * 0.6).rounded() }     // 5 / 7

    /// Body text: SF Pro (or SF Mono with the "Моноширинный" setting).
    public func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch fontStyle {
        case .system: return .system(size: size, weight: weight)
        case .mono: return .system(size: size, weight: weight, design: .monospaced)
        }
    }

    /// Figures and titles (IP address, countdown, headings): SF Pro Rounded, which echoes the
    /// capsule controls; SF Mono with the "Моноширинный" setting. Digits are tabular.
    public func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        switch fontStyle {
        case .system: return .system(size: size, weight: weight, design: .rounded).monospacedDigit()
        case .mono: return .system(size: size, weight: weight, design: .monospaced)
        }
    }

    /// Whether the resolved palette is the dark one (glass tints differ per scheme).
    public var isDark: Bool { palette.background.luminance < 0.2 }
}
