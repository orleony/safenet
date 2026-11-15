import SwiftUI
import SafeNetCore
import Combine

/// Corner radii and other fixed design constants.
public enum Metrics {
    public static let cornerRadius: CGFloat = 12
    public static let smallCornerRadius: CGFloat = 8
    public static let hairlineWidth: CGFloat = 1
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

    public func update(config: Config) { self.config = config; resolve() }
    public func update(systemScheme: ColorScheme) {
        guard systemScheme != self.systemScheme else { return }
        self.systemScheme = systemScheme; resolve()
    }

    private func resolve() {
        palette = SafeNetUI.palette(theme: config.theme, system: systemScheme, accent: AccentName(configValue: config.accent))
        spacing = scaledSpacing(config.density)
        fontStyle = config.fontStyle
    }

    public func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch fontStyle {
        case .system: return .system(size: size, weight: weight)
        case .mono: return .system(size: size, weight: weight, design: .monospaced)
        }
    }
}
