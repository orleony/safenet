import Foundation
import SafeNetCore

/// Pure text helpers for the menu bar and the window (Russian UI strings).
public enum Format {
    /// "NL" -> 🇳🇱 (regional indicator symbols); "" for anything that is not two ASCII letters.
    public static func flag(_ cc: String) -> String {
        let u = cc.uppercased()
        guard u.utf8.count == 2, u.utf8.allSatisfy({ $0 >= 65 && $0 <= 90 }) else { return "" }
        var s = ""
        for b in u.utf8 { s.unicodeScalars.append(Unicode.Scalar(0x1F1E6 + UInt32(b - 65))!) }
        return s
    }

    public static func countryName(_ cc: String) -> String {
        Locale(identifier: "ru_RU").localizedString(forRegionCode: cc.uppercased()) ?? cc.uppercased()
    }

    public static func reason(_ r: Reason) -> String {
        switch r {
        case .ipNotAllowed: return "IP не в списке разрешённых"
        case .countryNotAllowed: return "страна не разрешена"
        case .unconfirmed: return "IP не подтверждён: сервисы расходятся или не отвечают"
        case .ipv6Leak: return "утечка IPv6 мимо VPN"
        case .dnsLeak: return "утечка DNS"
        case .routeLeak: return "маршрут до ИИ-сервисов идёт мимо разрешённых адресов"
        case .networkChanged: return "сеть изменилась, идёт проверка"
        case .offline: return "нет сети"
        case .freezeFailed: return "не удалось заморозить приложение"
        }
    }

    /// 75 -> "01:15"; negative -> "00:00"; an hour or more -> "1:02:03".
    public static func countdown(_ seconds: TimeInterval) -> String {
        let t = max(0, Int(seconds.rounded(.up)))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// Menu bar title text (nil = show the icon only).
    public static func menuTitle(_ mode: MenubarDisplay, confirmed: IPAnswer?) -> String? {
        guard let a = confirmed else { return mode == .icon ? nil : "—" }
        switch mode {
        case .ip: return "\(flag(a.country)) \(a.ip)"
        case .country: return "\(flag(a.country)) \(a.country.uppercased())"
        case .icon: return nil
        }
    }

    /// SF Symbol per state (menu bar labels are template images, so the state is in the shape).
    public static func stateSymbol(_ s: GuardState) -> String {
        switch s {
        case .ok: return "checkmark.shield"
        case .frozen(_, let r, _): return r == .freezeFailed ? "xmark.shield" : "exclamationmark.shield"
        case .closed: return "xmark.shield"
        case .paused: return "pause.circle"
        }
    }

    public static func stateTitle(_ s: GuardState, hasApps: Bool) -> String {
        switch s {
        case .ok: return hasApps ? "Защита включена" : "Нет защищаемых приложений"
        case .frozen: return "Приложения заморожены"
        case .closed: return "Приложения закрыты"
        case .paused: return "Пауза"
        }
    }
}
