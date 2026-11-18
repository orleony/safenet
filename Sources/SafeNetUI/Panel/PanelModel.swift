import Foundation
import SafeNetCore

/// Result of validating one user input: the normalised value, or an error; plus an optional
/// warning for values that are accepted but probably not what the user wants.
public struct InputCheck<T: Equatable>: Equatable {
    public var value: T?
    public var error: String?
    public var warning: String?
    static func ok(_ v: T, warning: String? = nil) -> InputCheck { InputCheck(value: v, error: nil, warning: warning) }
    static func fail(_ e: String) -> InputCheck { InputCheck(value: nil, error: e, warning: nil) }
}

// MARK: - Allowed IPs and countries

public enum AllowInput {
    /// Exact IPv4/IPv6 address or CIDR subnet (validated by `IPMatcher`, the same code that matches).
    public static func ip(_ raw: String, existing: [String]) -> InputCheck<String> {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .fail("Введите IP-адрес (203.0.113.7) или подсеть (10.0.0.0/8)") }
        guard IPMatcher.isValidEntry(s) else {
            return .fail(s.contains("/") ? "Неверная подсеть: нужен адрес и длина префикса (IPv4 до /32, IPv6 до /128)"
                                         : "Это не IP-адрес. Пример: 203.0.113.7 или 2001:db8::1")
        }
        if existing.contains(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) { return .fail("Этот адрес уже в списке") }
        if let p = IPMatcher.prefixLength(s), p < (s.contains(":") ? 16 : 8) {
            return .ok(s, warning: "Очень широкая подсеть /\(p): разрешает огромную часть интернета")
        }
        return .ok(s)
    }

    /// Two-letter ISO 3166 code, uppercased; must be a real region.
    public static func country(_ raw: String, existing: [String]) -> InputCheck<String> {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard s.utf8.count == 2, s.utf8.allSatisfy({ $0 >= 65 && $0 <= 90 }) else {
            return .fail("Нужен двухбуквенный код страны латиницей, например NL или DE")
        }
        guard isoCodes.contains(s) else { return .fail("Нет страны с кодом \(s)") }
        if existing.contains(where: { $0.uppercased() == s }) { return .fail("Эта страна уже в списке") }
        return .ok(s)
    }

    public struct Country: Equatable, Hashable { public let code, name, flag: String }

    static let isoCodes: Set<String> = Set(Locale.Region.isoRegions.map { $0.identifier }.filter {
        $0.utf8.count == 2 && $0.utf8.allSatisfy { $0 >= 65 && $0 <= 90 }
    })

    /// Every ISO country, sorted by its Russian name (for the picker).
    public static let countryChoices: [Country] = isoCodes.map {
        Country(code: $0, name: Format.countryName($0), flag: Format.flag($0))
    }.sorted { $0.name.compare($1.name, locale: Locale(identifier: "ru_RU")) == .orderedAscending }
}

// MARK: - Custom apps

public enum CustomAppInput {
    public struct Report: Equatable, CustomStringConvertible {
        public var errors: [String] = []
        public var warnings: [String] = []
        public var description: String { "errors: \(errors), warnings: \(warnings)" }
    }

    static let broadNames: Set<String> = ["node", "python", "python3", "ruby", "perl", "java", "bash", "zsh", "sh", "fish",
                                          "electron", "helper", "deno", "bun", "osascript", "login"]
    static let broadPaths = ["/applications/", "/users/", "/usr/", "/usr/local/", "/opt/", "/opt/homebrew/", "/bin/",
                             "/library/", ".app/", "/contents/", "/macos/", "/contents/macos/", "/frameworks/"]
    static let broadArgs: Set<String> = ["http", "https", "node", "python", "python3", ".js", ".py", "/users/", "--type"]

    /// Errors refuse saving; warnings are shown but the rule can be saved.
    public static func check(name: String, match: String, config: Config, editing: String?,
                             fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Report {
        var r = Report()
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { r.errors.append("Введите название") }
        if !n.isEmpty, n != editing {
            if config.customApps.contains(where: { $0.name == n }) { r.errors.append("Приложение с таким названием уже есть") }
            if AppCatalog.preset(n) != nil { r.errors.append("Это название занято готовым набором «\(AppCatalog.displayName(for: n))»") }
        }
        let parts = match.components(separatedBy: "&&")
        for p in parts {
            if let e = partError(p) { r.errors.append(parts.count > 1 ? "Условие «\(p.trimmingCharacters(in: .whitespaces))»: \(e)" : e) }
        }
        if r.errors.isEmpty, parts.count == 1, let w = broadWarning(match) { r.warnings.append(w) }
        if r.errors.isEmpty, let w = systemOnlyWarning(parts, fileExists: fileExists) { r.warnings.append(w) }
        return r
    }

    static let systemOnlyText = "Похоже, это системное приложение (из /System): macOS не даёт его замораживать и закрывать — SafeNet покажет его как «не защищается», а работать оно будет без ограничений. Для проверки используйте приложение из папки «Программы»."

    /// The rule can only find protected system processes: a path rule under a never-freeze
    /// prefix (/System/, /usr/libexec/, …), or a plain name that exists only as a /System app
    /// (e.g. "Notes", "TextEdit") and not in /Applications or ~/Applications.
    static func systemOnlyWarning(_ parts: [String], fileExists: (String) -> Bool) -> String? {
        for part in parts {
            let (kind, text) = content(part)
            if kind == "path" {
                let l = text.lowercased()
                if neverFreezePathPrefixes.contains(where: { l.hasPrefix($0) || l.hasPrefix(String($0.dropLast())) }) {
                    return systemOnlyText
                }
            }
            if kind == "name" {
                let n = text.hasSuffix(".app") ? String(text.dropLast(4)) : text
                let system = ["/System/Applications/\(n).app", "/System/Applications/Utilities/\(n).app",
                              "/System/Library/CoreServices/\(n).app"]
                let user = ["/Applications/\(n).app", NSHomeDirectory() + "/Applications/\(n).app"]
                if system.contains(where: fileExists) && !user.contains(where: fileExists) { return systemOnlyText }
            }
        }
        return nil
    }

    private static func content(_ part: String) -> (kind: String, text: String) {
        let t = part.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = t.lowercased()
        if l.hasPrefix("args:") { return ("args", String(t.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)) }
        if l.hasPrefix("cmd:") { return ("cmd", String(t.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)) }
        if t.contains("/") { return ("path", t) }
        return ("name", t)
    }

    private static func partError(_ part: String) -> String? {
        let (kind, text) = content(part)
        let significant = text.filter { $0 != "/" && !$0.isWhitespace }
        if significant.isEmpty { return "пустое правило ничего не найдёт" }
        if significant.count < 3 { return "слишком короткое правило (нужно не меньше 3 символов) — оно задело бы чужие процессы" }
        if kind == "cmd", text.contains("/") { return "после cmd: укажите только имя команды, без пути" }
        return nil
    }

    private static func broadWarning(_ match: String) -> String? {
        let (kind, text) = content(match)
        let l = text.lowercased()
        switch kind {
        case "name" where broadNames.contains(l):
            return "Слишком общее имя: будут заморожены ВСЕ процессы «\(text)». Уточните путь или добавьте условие (например «\(text) && args:мой-скрипт»)"
        case "path" where broadPaths.contains(l) || l.filter({ $0 != "/" }).count < 5:
            return "Слишком общий путь: под него попадёт много программ"
        case "args" where broadArgs.contains(l) || l.hasPrefix("-") || l.count < 5:
            return "Слишком общий фрагмент: встречается в командных строках многих программ"
        default:
            return nil
        }
    }

    /// Plain-language description of a match rule (shown next to the field).
    public static func kindText(_ match: String) -> String {
        let parts = match.components(separatedBy: "&&")
        if parts.count > 1 {
            let short = parts.map { p -> String in
                switch content(p).kind { case "args": return "командная строка"; case "cmd": return "команда"; case "path": return "путь"; default: return "имя" }
            }
            return "все условия сразу (" + short.joined(separator: " + ") + ")"
        }
        switch content(match).kind {
        case "args": return "по части командной строки"
        case "cmd": return "по имени команды (первые слова командной строки)"
        case "path": return "по части пути к программе"
        default: return "по имени процесса"
        }
    }
}

// MARK: - Durations, accent

public enum DurationInput {
    /// Freeze time (grace): one range for the common setting and per-app overrides.
    public static let graceRange: ClosedRange<Double> = 5...600

    public enum Unit { case seconds, minutes }

    /// A duration in `unit` ("20", "1,5", or with a suffix "30s", "2m", "1h") inside `range`
    /// (also in `unit`): with `.minutes` "2m" is 2 minutes and "90s" 1.5.
    public static func parse(_ raw: String, range: ClosedRange<Double>, unit: Unit = .seconds) -> InputCheck<Double> {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".").lowercased()
        var seconds: Double? = nil
        if let last = t.last, "smh".contains(last) { seconds = last == "s" ? 1 : last == "m" ? 60 : 3600; t.removeLast() }
        let perUnit: Double = unit == .seconds ? 1 : 60
        let name = unit == .seconds ? "секунд" : "минут"
        let msg = "Введите число \(name) от \(text(range.lowerBound)) до \(text(range.upperBound))"
        guard let d = Double(t.trimmingCharacters(in: .whitespaces)), d.isFinite else { return .fail(msg) }
        let v = seconds.map { d * $0 / perUnit } ?? d
        return range.contains(v) ? .ok(v) : .fail(msg)
    }

    public static func text(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e9 ? String(Int(v)) : String(v)
    }
}

public enum AccentInput {
    /// "#RRGGBB" / "RRGGBB" -> config value "#rrggbb"; anything else nil.
    public static func parse(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rgb = RGB(hex: t) else { return nil }
        return rgb.hexString
    }
}

// MARK: - Trusted networks

public enum NetworkInput {
    /// "Доверять этой сети" from the current snapshot: needs gateway IP + MAC + subnet.
    public static func trust(_ s: NetSnapshot?, existing: [TrustedNetwork]) -> (network: TrustedNetwork?, reason: String?) {
        guard let s = s, s.online else { return (nil, "Нет сети") }
        guard let gw = s.gatewayIP else {
            return (nil, s.hasTunnel
                ? "Шлюз не виден: пока VPN забирает весь трафик, сеть опознать нельзя. Выключите VPN, добавьте сеть и включите VPN обратно."
                : "Шлюз сети не найден")
        }
        guard let raw = s.gatewayMAC, let mac = normalizeMAC(raw) else { return (nil, "MAC-адрес шлюза неизвестен (нет записи ARP), опознать сеть нельзя") }
        guard let subnet = s.subnet, subnet.contains("/") else { return (nil, "Подсеть неизвестна, опознать сеть нельзя") }
        let n = TrustedNetwork(name: "Сеть \(gw)", mac: mac, ip: gw, subnet: subnet)
        if isTrusted(s, existing) { return (nil, "Эта сеть уже в списке доверенных") }
        return (n, nil)
    }

    /// Error text, or nil when the new name is fine.
    public static func rename(_ name: String, index: Int, in list: [TrustedNetwork]) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return "Введите название" }
        if list.enumerated().contains(where: { $0.offset != index && $0.element.name == n }) { return "Такое название уже есть" }
        return nil
    }
}

// MARK: - Journal texts

public enum EventText {
    public struct Filter: Equatable { public let title: String; public let kinds: Set<EventKind> }

    public static let filters: [Filter] = [
        Filter(title: "Заморозки", kinds: [.frozen]),
        Filter(title: "Разморозки", kinds: [.resumed]),
        Filter(title: "Закрытия", kinds: [.closed]),
        Filter(title: "Сеть", kinds: [.networkChanged, .ipChanged]),
        Filter(title: "Утечки", kinds: [.leak]),
        Filter(title: "Пауза", kinds: [.paused]),
    ]

    public static func filterTitle(_ k: EventKind) -> String { filters.first { $0.kinds.contains(k) }?.title ?? "" }

    static func reason(_ code: String) -> Reason? {
        let all: [Reason] = [.ipNotAllowed, .countryNotAllowed, .unconfirmed, .ipv6Leak, .dnsLeak, .routeLeak,
                             .networkChanged, .offline, .freezeFailed, .noAllowList]
        return all.first { "\($0)" == code }
    }

    /// Human-readable Russian line for one history entry.
    public static func describe(_ e: Event) -> String {
        let who = e.app.map { AppCatalog.displayName(for: $0) + ": " } ?? ""
        let why = reason(e.detail).map { Format.reason($0) }
        switch (e.kind, e.detail) {
        case (.frozen, _): return who + "заморожено" + (why.map { " — " + $0 } ?? "")
        case (.closed, "timeout"): return who + "закрыто — истёк срок заморозки"
        case (.closed, "closeNow"): return who + "закрыто вручную («Закрыть сейчас»)"
        case (.closed, _): return who + "закрыто"
        case (.resumed, "checkPassed"): return who + "разморожено — проверка пройдена"
        case (.resumed, _): return who + "разморожено"
        case (.paused, "pause"): return "Защита на паузе"
        case (.paused, "resumeProtection"): return "Защита возобновлена"
        case (.paused, "timeoutResume"): return who + "разморожено по истечении срока (настройка «Разморозить»)"
        case (.paused, _): return who + "пауза"
        case (.leak, "freezeFailed"): return who + "не удалось заморозить"
        case (.leak, "unprotectable"): return who + "системное приложение — не защищается (работает без ограничений)"
        case (.leak, _):
            if let w = why { return who + w.prefix(1).uppercased() + String(w.dropFirst()) }
            return who + "Утечка"
        case (.networkChanged, _): return "Сеть изменилась"
        case (.ipChanged, _): return "Внешний IP изменился"
        }
    }

    /// SF Symbol per kind (the meaning is also in the text, never colour alone).
    public static func symbol(_ k: EventKind) -> String {
        switch k {
        case .frozen: return "snowflake"
        case .resumed: return "play.circle"
        case .closed: return "xmark.circle"
        case .paused: return "pause.circle"
        case .leak: return "exclamationmark.triangle"
        case .networkChanged: return "wifi"
        case .ipChanged: return "arrow.triangle.2.circlepath"
        }
    }
}

// MARK: - Config mutations used by the panel (all go through AppState.update)

public enum ConfigEdit {
    /// Adds (original nil) or replaces a custom app; a rename moves its rules, grace and `apps` entry.
    public static func saveCustom(_ c: inout Config, original: String?, name: String, match: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = CustomApp(name: n, match: match.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let o = original, let i = c.customApps.firstIndex(where: { $0.name == o }) else {
            c.customApps.append(app); return
        }
        c.customApps[i] = app
        guard o != n else { return }
        if let r = c.appRules.removeValue(forKey: o) { c.appRules[n] = r }
        if let g = c.appGrace.removeValue(forKey: o) { c.appGrace[n] = g }
        c.apps = c.apps.map { $0 == o ? n : $0 }
    }

    public static func deleteCustom(_ c: inout Config, _ name: String) {
        c.customApps.removeAll { $0.name == name }
        c.appRules[name] = nil
        c.appGrace[name] = nil
        c.apps.removeAll { $0 == name }
    }

    /// Off: the app gets its own list, starting as a copy of the common one (no instant freeze).
    public static func setUseCommonRules(_ c: inout Config, _ id: String, _ common: Bool) {
        c.appRules[id] = common ? nil : (c.appRules[id] ?? c.allow)
    }

    public static func setUseCommonGrace(_ c: inout Config, _ id: String, _ common: Bool) {
        c.appGrace[id] = common ? nil : (c.appGrace[id] ?? c.grace)
    }
}
