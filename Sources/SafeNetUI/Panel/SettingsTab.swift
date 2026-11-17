import SwiftUI
import SafeNetCore

/// "Настройки": every Config parameter. Each change goes through `AppState.update` (the engine's
/// update path: written to config.yaml, refused in test mode, broken file copied first).
struct SettingsTab: View {
    @ObservedObject var model: AppState
    @EnvironmentObject var theme: Theme

    /// IPv4 IP services taking part in the quorum (min_agree above this can never be met).
    static let serviceCount = HTTPIPService.defaults.count

    var body: some View {
        let p = theme.palette
        let c = model.config
        VStack(alignment: .leading, spacing: theme.spacing + 2) {
            SectionHeader(title: "Настройки", subtitle: "Всё сохраняется в config.yaml; правки файла вручную сразу появляются здесь.")
            if model.configReadOnly { Note(LiveSystem.readOnlyMessage, symbol: "info.circle", color: p.frozen) }
            Card {
                Text("Заморозка и закрытие").font(theme.font(12, weight: .semibold)).foregroundColor(p.text.swiftUIColor)
                durationRow("Время заморозки", "Сколько ждать правильный IP, прежде чем выполнить действие ниже (5–600 с).",
                            c.grace, 5...600) { v in model.update { $0.grace = v } }
                SettingRow("Когда время вышло", detail: timeoutDetail(c.onTimeout)) {
                    Segmented(options: [(TimeoutAction.close, "Закрыть"), (.keepFrozen, "Держать замороженным"), (.resume, "Разморозить")],
                              selection: c.onTimeout) { v in model.update { $0.onTimeout = v } }
                }
                if c.onTimeout == .resume {
                    Note("«Разморозить» снова пускает приложения в сеть с неправильного адреса. Используйте, только если понимаете риск.",
                         symbol: "exclamationmark.triangle", color: p.danger)
                }
                durationRow("Ожидание при закрытии", "После вежливой просьбы закрыться — сколько ждать до принудительного (0–60 с).",
                            c.closeTimeout, 0...60) { v in model.update { $0.closeTimeout = v } }
                SettingRow("Без сети замораживать", detail: "Без сети ничего не утекает, поэтому приложения только замораживаются и никогда не закрываются.") {
                    toggle("Без сети замораживать", c.blockWhenOffline) { v in model.update { $0.blockWhenOffline = v } }
                }
                durationRow("Пауза по умолчанию, мин", "Длина «Паузы» из меню и Обзора (1–1440 мин).", c.pauseDefault / 60, 1...1440) { v in
                    model.update { $0.pauseDefault = v * 60 }
                }
            }
            Card {
                Text("Проверки").font(theme.font(12, weight: .semibold)).foregroundColor(p.text.swiftUIColor)
                durationRow("Интервал проверки", "Опрос IP по таймеру в дополнение к системным событиям сети (1–300 с).",
                            c.checkInterval, 1...300) { v in model.update { $0.checkInterval = v } }
                SettingRow("Сколько сервисов должны совпасть",
                           detail: "IP подтверждён, когда столько сервисов назвали один IP и одну страну. 1 — быстрее, но один ошибочный ответ решает всё; 2 — рекомендуется; \(SettingsTab.serviceCount) — любое расхождение замораживает.") {
                    Segmented(options: (1...SettingsTab.serviceCount).map { ($0, "\($0)") }, selection: c.minAgree) { v in model.update { $0.minAgree = v } }
                }
                if c.minAgree > SettingsTab.serviceCount {
                    Note("Сейчас \(c.minAgree), а сервисов \(SettingsTab.serviceCount): IP никогда не подтвердится и приложения будут заморожены всегда.",
                         symbol: "exclamationmark.triangle", color: p.danger)
                }
                SettingRow("Проверять IPv6", detail: "Замораживать, если IPv6 выходит мимо VPN.") {
                    toggle("Проверять IPv6", c.checkIPv6) { v in model.update { $0.checkIPv6 = v } }
                }
                SettingRow("Проверка DNS", detail: dnsDetail(c.dnsCheck)) {
                    Segmented(options: [(DNSCheckMode.warn, "Предупреждать"), (.block, "Замораживать"), (.off, "Выключена")],
                              selection: c.dnsCheck) { v in model.update { $0.dnsCheck = v } }
                }
                SettingRow("Маршрут до ИИ-сервисов", detail: "Раз в 2 минуты и после смены сети спрашивает /cdn-cgi/trace у пяти ИИ-сервисов (только когда есть защищаемые приложения).") {
                    toggle("Маршрут до ИИ-сервисов", c.routeCheck) { v in model.update { $0.routeCheck = v } }
                }
            }
            AppearanceSettings(model: model)
            SystemSettings(model: model)
        }
    }

    private func timeoutDetail(_ a: TimeoutAction) -> String {
        switch a {
        case .close: return "Приложение закрывается (рекомендуется)."
        case .keepFrozen: return "Приложение остаётся замороженным, пока адрес не станет правильным."
        case .resume: return "Приложение размораживается и работает дальше."
        }
    }

    private func dnsDetail(_ m: DNSCheckMode) -> String {
        switch m {
        case .warn: return "Возможная утечка DNS показывается предупреждением."
        case .block: return "Возможная утечка DNS замораживает приложения (у корпоративных VPN бывают ложные срабатывания)."
        case .off: return "DNS не проверяется."
        }
    }

    func toggle(_ label: String, _ on: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        Toggle(label, isOn: Binding(get: { on }, set: set)).toggleStyle(SNSwitchStyle(theme: theme, showLabel: false)).fixedSize()
            .accessibilityLabel(label)
    }

    func durationRow(_ title: String, _ detail: String, _ value: Double, _ range: ClosedRange<Double>,
                     _ set: @escaping (Double) -> Void) -> some View {
        SettingRow(title, detail: detail) {
            ValidatedField(label: title, placeholder: "", actionTitle: "OK", initial: DurationInput.text(value), width: 70,
                           validate: { r in let x = DurationInput.parse(r, range: range); return InputCheck(value: x.value.map { DurationInput.text($0) }, error: x.error, warning: nil) },
                           commit: { v in if let d = DurationInput.parse(v, range: range).value { set(d) } })
                .frame(width: 220, alignment: .trailing)
                .id(value)                      // re-initialised after a hot reload changed the value
        }
    }
}
