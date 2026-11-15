import SwiftUI
import SafeNetCore
@testable import SafeNetUI

private let allAccents: [AccentName] = [.blue, .violet, .orange, .pink, .neutral, .custom("#808080"), .custom("#ffff00"), .custom("#000000")]
private let schemes: [ColorScheme] = [.light, .dark]

func registerThemeTests() {
    test("testSystemThemeFollowsColorScheme") {
        expectEqual(palette(theme: .system, system: .dark, accent: .blue), palette(theme: .dark, system: .light, accent: .blue))
        expectEqual(palette(theme: .system, system: .light, accent: .blue), palette(theme: .light, system: .dark, accent: .blue))
        expect(palette(theme: .system, system: .dark, accent: .blue) != palette(theme: .system, system: .light, accent: .blue))
    }
    test("testExplicitThemeIgnoresSystem") {
        expectEqual(palette(theme: .dark, system: .light, accent: .pink), palette(theme: .dark, system: .dark, accent: .pink))
        expectEqual(palette(theme: .light, system: .light, accent: .pink), palette(theme: .light, system: .dark, accent: .pink))
        expectEqual(palette(theme: .dark, system: .light, accent: .blue).background, RGB(hex: "#1a1c25")!)
        expectEqual(palette(theme: .light, system: .dark, accent: .blue).background, RGB(hex: "#fbfbfd")!)
    }
    test("testAccentDoesNotChangeStatusColors") {
        for s in schemes {
            let base = palette(theme: .system, system: s, accent: .blue)
            for a in allAccents {
                let p = palette(theme: .system, system: s, accent: a)
                expectEqual(p.ok, base.ok); expectEqual(p.frozen, base.frozen); expectEqual(p.danger, base.danger)
            }
        }
        expectEqual(palette(theme: .dark, system: .dark, accent: .blue).ok, RGB(hex: "#34d399")!)
        expectEqual(palette(theme: .dark, system: .dark, accent: .blue).frozen, RGB(hex: "#ffb454")!)
        expectEqual(palette(theme: .dark, system: .dark, accent: .blue).danger, RGB(hex: "#ff6b6b")!)
    }
    test("testBlueIsDefault") {
        expectEqual(AccentName(configValue: "blue"), .blue)
        expectEqual(AccentName(configValue: "nonsense"), .blue)
        expectEqual(AccentName(configValue: ""), .blue)
        expectEqual(AccentName(configValue: Config.default.accent), .blue)
        expectEqual(palette(theme: .dark, system: .dark, accent: AccentName(configValue: "zzz")).accent,
                    palette(theme: .dark, system: .dark, accent: .blue).accent)
    }
    test("testTextOnAccentMeetsContrast45") {
        for s in schemes {
            for a in allAccents {
                let p = palette(theme: .system, system: s, accent: a)
                let c = contrastRatio(p.onAccent, p.accent)
                expect(c >= 4.5, "\(a) \(s) contrast \(c)")
            }
        }
    }
    test("testCustomHexParses") {
        expectEqual(AccentName(configValue: "#FF8800"), .custom("#ff8800"))
        let p = palette(theme: .dark, system: .dark, accent: AccentName(configValue: "#ff8800"))
        expectEqual(p.accent, RGB(hex: "#ff8800")!)
        expectEqual(RGB(hex: "#000000"), RGB(r: 0, g: 0, b: 0))
        expectEqual(RGB(hex: "ffffff"), RGB(r: 1, g: 1, b: 1))
    }
    test("testInvalidCustomHexFallsBackToBlue") {
        for bad in ["#12", "#gggggg", "#12345678", "#", "#ff88zz"] {
            expectEqual(AccentName(configValue: bad), .blue, bad)
        }
        expect(RGB(hex: "#12345") == nil)
    }
    test("testAccentConfigValueRoundTrips") {
        for a in allAccents { expectEqual(AccentName(configValue: a.configValue), a) }
        expectEqual(AccentName.violet.configValue, "violet")
        expectEqual(AccentName.custom("#ABCDEF").configValue, "#abcdef")
    }
    test("testTextAndMutedContrastAtLeast45") {
        for s in schemes {
            let p = palette(theme: .system, system: s, accent: .blue)
            expect(contrastRatio(p.text, p.background) >= 4.5)
            expect(contrastRatio(p.muted, p.background) >= 4.5)
            expect(contrastRatio(p.muted, p.surface) >= 4.5, "muted on surface \(s)")
            expect(contrastRatio(p.text, p.surface) >= 4.5)
        }
    }
    test("testStatusColorsContrastAtLeast3") {
        for s in schemes {
            let p = palette(theme: .system, system: s, accent: .blue)
            for c in [p.ok, p.frozen, p.danger] { expect(contrastRatio(c, p.background) >= 3.0, "\(s)") }
        }
    }
    test("testCompactSpacingSmallerThanComfortable") {
        expect(scaledSpacing(.compact) < scaledSpacing(.comfortable))
        expect(scaledSpacing(.compact) > 0)
    }
    test("testThemeBuildsFromConfig") {
        var cfg = Config.default
        cfg.theme = .system; cfg.accent = "#ff8800"; cfg.density = .compact; cfg.fontStyle = .mono
        let t = Theme(config: cfg, systemScheme: .dark)
        expectEqual(t.palette, palette(theme: .system, system: .dark, accent: .custom("#ff8800")))
        expectEqual(t.spacing, scaledSpacing(.compact))
        t.update(systemScheme: .light)
        expectEqual(t.palette.background, RGB(hex: "#fbfbfd")!)
        t.update(config: Config.default)
        expectEqual(t.fontStyle, .system)
    }
}

import Combine

func registerSystemAppearanceTests() {
    test("testSystemAppearanceReadsStyle") {
        let none = PassthroughSubject<Void, Never>().eraseToAnyPublisher()
        expectEqual(SystemAppearance(provider: { "Dark" }, changes: none).scheme, .dark)
        expectEqual(SystemAppearance(provider: { nil }, changes: none).scheme, .light)
        expectEqual(SystemAppearance(provider: { "Light" }, changes: none).scheme, .light)
        expectEqual(SystemAppearance(provider: { "weird" }, changes: none).scheme, .light)
    }
    test("testSystemAppearanceNotificationRereads") {
        var style: String? = nil
        let subj = PassthroughSubject<Void, Never>()
        let a = SystemAppearance(provider: { style }, changes: subj.eraseToAnyPublisher())
        expectEqual(a.scheme, .light)
        style = "Dark"
        subj.send(())
        let exp = Date().addingTimeInterval(2)
        while a.scheme != .dark && Date() < exp { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        expectEqual(a.scheme, .dark)
    }
    test("testThemeFollowsSystemAppearanceAndForcedIgnores") {
        var style: String? = "Dark"
        let a = SystemAppearance(provider: { style }, changes: Empty().eraseToAnyPublisher())
        var cfg = Config.default
        cfg.theme = .system
        let sys = Theme(config: cfg, appearance: a)
        cfg.theme = .light
        let forced = Theme(config: cfg, appearance: a)
        expectEqual(sys.palette.background, RGB(hex: "#1a1c25")!)
        expectEqual(forced.palette.background, RGB(hex: "#fbfbfd")!)
        style = nil; a.refresh()
        expectEqual(sys.palette.background, RGB(hex: "#fbfbfd")!)
        expectEqual(forced.palette.background, RGB(hex: "#fbfbfd")!)
        style = "Dark"; a.refresh()
        expectEqual(sys.palette.background, RGB(hex: "#1a1c25")!)
        expectEqual(forced.palette.background, RGB(hex: "#fbfbfd")!)
        expectEqual(sys.forcedScheme, nil)
        expectEqual(forced.forcedScheme, .light)
        cfg.theme = .dark
        forced.update(config: cfg)
        expectEqual(forced.forcedScheme, .dark)
    }
}
