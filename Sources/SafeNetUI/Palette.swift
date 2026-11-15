import SwiftUI
import SafeNetCore

/// Colour as plain sRGB components (0...1). Kept free of SwiftUI so palette logic is testable headlessly.
public struct RGB: Equatable {
    public var r: Double, g: Double, b: Double
    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    /// Parses "#RRGGBB" or "RRGGBB" (case-insensitive). Anything else returns nil.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy({ $0.isASCII && $0.isHexDigit }), let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: Double((v >> 16) & 0xff) / 255, g: Double((v >> 8) & 0xff) / 255, b: Double(v & 0xff) / 255)
    }

    public var hexString: String {
        func c(_ x: Double) -> Int { Int((x * 255).rounded()) }
        return String(format: "#%02x%02x%02x", c(r), c(g), c(b))
    }

    public var swiftUIColor: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }

    /// WCAG relative luminance.
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
}

/// WCAG contrast ratio (1...21).
public func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
    let la = a.luminance, lb = b.luminance
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

public enum AccentName: Equatable {
    case blue, violet, orange, pink, neutral
    case custom(String)

    /// Config stores "blue" / "violet" / ... or "#RRGGBB". Unknown or invalid hex falls back to blue.
    public init(configValue: String) {
        let v = configValue.trimmingCharacters(in: .whitespaces).lowercased()
        switch v {
        case "blue": self = .blue
        case "violet": self = .violet
        case "orange": self = .orange
        case "pink": self = .pink
        case "neutral": self = .neutral
        default:
            if v.hasPrefix("#"), let rgb = RGB(hex: v) { self = .custom(rgb.hexString) } else { self = .blue }
        }
    }

    public var configValue: String {
        switch self {
        case .blue: return "blue"
        case .violet: return "violet"
        case .orange: return "orange"
        case .pink: return "pink"
        case .neutral: return "neutral"
        case .custom(let h): return RGB(hex: h)?.hexString ?? "blue"
        }
    }

    func color(dark: Bool) -> RGB {
        func h(_ s: String) -> RGB { RGB(hex: s)! }
        switch self {
        case .blue: return h(dark ? "#4c9aff" : "#0071e3")
        case .violet: return h(dark ? "#8b7bff" : "#6a55e0")
        case .orange: return h(dark ? "#ff8a4c" : "#c4560f")
        case .pink: return h(dark ? "#ff5c9a" : "#d6246e")
        case .neutral: return h(dark ? "#cfd3e0" : "#3a3a3c")
        case .custom(let hex): return RGB(hex: hex) ?? h(dark ? "#4c9aff" : "#0071e3")
        }
    }
}

public struct Palette: Equatable {
    public var background, surface, sidebar, sidebarActive, text, muted, hairline: RGB
    public var accent, onAccent: RGB
    public var ok, frozen, danger: RGB
}

/// Picks the text colour for an accent fill: dark ink, white, or black, whichever first reaches 4.5:1.
func onAccentColor(for accent: RGB) -> RGB {
    let candidates = [RGB(hex: "#14161e")!, RGB(r: 1, g: 1, b: 1), RGB(r: 0, g: 0, b: 0)]
    var best = candidates[0]
    for c in candidates {
        if contrastRatio(c, accent) >= 4.5 { return c }
        if contrastRatio(c, accent) > contrastRatio(best, accent) { best = c }
    }
    return best
}

public func palette(theme: ThemeChoice, system: ColorScheme, accent: AccentName) -> Palette {
    let dark: Bool
    switch theme {
    case .dark: dark = true
    case .light: dark = false
    case .system: dark = (system == .dark)
    }
    func h(_ s: String) -> RGB { RGB(hex: s)! }
    let acc = accent.color(dark: dark)
    if dark {
        return Palette(background: h("#1a1c25"), surface: h("#242736"), sidebar: h("#14161e"), sidebarActive: h("#2a2d3f"),
                       text: h("#eef0f6"), muted: h("#9ba0b8"), hairline: h("#333749"),
                       accent: acc, onAccent: onAccentColor(for: acc),
                       ok: h("#34d399"), frozen: h("#ffb454"), danger: h("#ff6b6b"))
    }
    return Palette(background: h("#fbfbfd"), surface: h("#f0f0f5"), sidebar: h("#f0f0f5"), sidebarActive: h("#e2e2ec"),
                   text: h("#1d1d1f"), muted: h("#636366"), hairline: h("#dcdce4"),
                   accent: acc, onAccent: onAccentColor(for: acc),
                   ok: h("#1f8a4c"), frozen: h("#b25e00"), danger: h("#c92a2a"))
}

public func scaledSpacing(_ d: Density) -> CGFloat {
    switch d {
    case .compact: return 8
    case .comfortable: return 12
    }
}
