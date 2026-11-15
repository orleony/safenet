import SwiftUI
import SafeNetCore

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

    public init(config: Config = .default, systemScheme: ColorScheme = .dark) {
        self.config = config; self.systemScheme = systemScheme
        palette = SafeNetUI.palette(theme: config.theme, system: systemScheme, accent: AccentName(configValue: config.accent))
        spacing = scaledSpacing(config.density)
        fontStyle = config.fontStyle
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

/// Publishes the environment colour scheme into the Theme so "as system" re-resolves live on appearance change.
private struct ThemeSchemeSync: ViewModifier {
    @ObservedObject var theme: Theme
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .onAppear { theme.update(systemScheme: scheme) }
            .onChange(of: scheme) { theme.update(systemScheme: $0) }
    }
}

public extension View {
    /// Attach at the root of every window/popover so the Theme follows macOS appearance without a restart.
    func syncingTheme(_ theme: Theme) -> some View { modifier(ThemeSchemeSync(theme: theme)) }
}
