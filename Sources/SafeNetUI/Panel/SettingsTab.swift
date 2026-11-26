import SwiftUI
import SafeNetCore

/// Summary of the common rule. Individual applications can override the allow list or timeout.
struct InspectorFreezeRule {
    let duration: String?
    let outcome: String

    init(config: Config) {
        if config.allow.ips.isEmpty && config.allow.countries.isEmpty {
            duration = nil
            outcome = "Без таймера закрытия"
            return
        }

        let seconds = "\(DurationInput.text(config.grace)) с"
        switch config.onTimeout {
        case .close:
            duration = seconds
            outcome = "Закрытие приложений"
        case .keepFrozen:
            duration = nil
            outcome = "До успешной проверки"
        case .resume:
            duration = seconds
            outcome = "Разморозка приложений"
        }
    }
}

struct SettingsTab: View {
    @ObservedObject var model: AppState
    @EnvironmentObject var theme: Theme
    let useColumns: Bool
    @State private var section: Section = .protection

    private enum Section: String, CaseIterable {
        case protection = "Защита"
        case appearance = "Внешний вид"
        case system = "Система"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.padding) {
            Text("Настройки")
                .font(theme.font(26, weight: .semibold))
                .foregroundColor(theme.palette.text.swiftUIColor)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: theme.spacing * 2) {
                ForEach(Section.allCases, id: \.self) { tab in
                    InspectorTabButton(title: tab.rawValue, selected: section == tab) { section = tab }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .bottom) {
                Rectangle().fill(theme.palette.hairline.swiftUIColor.opacity(0.7)).frame(height: 1)
            }

            if model.configReadOnly {
                Note(LiveSystem.readOnlyMessage, symbol: "info.circle", color: theme.palette.frozen)
            }
            if let error = model.configError {
                Note(error, symbol: "xmark.octagon", color: theme.palette.danger)
            }

            switch section {
            case .protection: protection
            case .appearance: AppearanceSettings(model: model)
            case .system: SystemSettings(model: model)
            }
        }
    }

    private var protection: some View {
        let columns = useColumns
            ? AnyLayout(HStackLayout(alignment: .top, spacing: theme.padding + 6))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: theme.padding + 6))

        return VStack(alignment: .leading, spacing: theme.padding + 6) {
            ruleSummary
            columns {
                freezing.frame(maxWidth: .infinity, alignment: .topLeading)
                network.frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var ruleSummary: some View {
        let p = theme.palette
        let rule = InspectorFreezeRule(config: model.config)

        return HStack(spacing: theme.smallGap + 4) {
            Text("Правило по умолчанию").foregroundColor(p.muted.swiftUIColor)
            Text("Заморозка").foregroundColor(p.text.swiftUIColor)
            if let duration = rule.duration {
                summaryArrow
                Text(duration).monospacedDigit().fontWeight(.semibold)
                    .foregroundColor(p.text.swiftUIColor)
            }
            summaryArrow
            Text(rule.outcome).foregroundColor(p.text.swiftUIColor)
        }
        .font(theme.font(11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, theme.padding)
        .padding(.vertical, theme.rowPadding + 2)
        .background(p.surface.swiftUIColor, in: RoundedRectangle(cornerRadius: Metrics.smallCornerRadius))
        .help("При неподтверждённом IP. Правила отдельных приложений могут отличаться.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(["Правило по умолчанию при неподтверждённом IP", "Заморозка", rule.duration, rule.outcome]
            .compactMap { $0 }.joined(separator: ", "))
    }

    private var summaryArrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 9))
            .foregroundColor(theme.palette.muted.swiftUIColor)
            .accessibilityHidden(true)
    }

    private var freezing: some View {
        let config = model.config

        return VStack(alignment: .leading, spacing: theme.smallGap + 3) {
            InspectorSettingsGroup("Заморозка и закрытие") {
                durationRow("Время заморозки", \.grace, DurationInput.graceRange)
                InspectorSettingsDivider()
                InspectorSettingRow("По истечении времени") {
                    Picker("По истечении времени", selection: Binding(get: { model.config.onTimeout },
                                                                      set: { value in model.update { $0.onTimeout = value } })) {
                        Text("Закрыть приложения").tag(TimeoutAction.close)
                        Text("Держать замороженными").tag(TimeoutAction.keepFrozen)
                        Text("Разморозить").tag(TimeoutAction.resume)
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
                if config.onTimeout == .resume {
                    Note("Приложения снова смогут выйти в сеть с неподтверждённого адреса.",
                         symbol: "exclamationmark.triangle", color: theme.palette.danger)
                        .padding(.horizontal, theme.padding).padding(.bottom, theme.rowPadding)
                }
                InspectorSettingsDivider()
                InspectorSettingRow("Замораживать без сети", detail: "Пока сети нет, приложения не закрываются.") {
                    toggle("Замораживать без сети", config.blockWhenOffline) { value in
                        model.update { $0.blockWhenOffline = value }
                    }
                }
                InspectorSettingsDivider()
                durationRow("Пауза по умолчанию", \.pauseDefault, 1...1440, unit: .minutes)
            }

            disclosure("Расширенные параметры закрытия") {
                InspectorSettingsGroup {
                    durationRow("Ожидание при закрытии", \.closeTimeout, 0...60,
                                detail: "До принудительного завершения приложения.")
                }
            }
        }
    }

    private var network: some View {
        let config = model.config

        return VStack(alignment: .leading, spacing: theme.smallGap + 3) {
            InspectorSettingsGroup("Проверки сети") {
                durationRow("Интервал проверки IP", \.checkInterval, 1...300)
                InspectorSettingsDivider()
                InspectorSettingRow("Совпадений для подтверждения") {
                    let count = config.ipServices.count
                    Picker("Совпадений для подтверждения", selection: Binding(get: { model.config.minAgree },
                                                                             set: { value in model.update { $0.minAgree = value } })) {
                        if config.minAgree > count {
                            Text("\(config.minAgree) из \(count)").tag(config.minAgree)
                        }
                        ForEach(1...max(1, count), id: \.self) { number in
                            Text("\(number) из \(count)").tag(number)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                    .help("Сколько включённых сервисов должны вернуть одинаковый внешний IP. Страна проверяется отдельно.")
                }
                if config.minAgree > config.ipServices.count {
                    Note("Требуется \(config.minAgree) совпадений, но включено \(config.ipServices.count) сервисов.",
                         symbol: "exclamationmark.triangle", color: theme.palette.danger)
                        .padding(.horizontal, theme.padding).padding(.bottom, theme.rowPadding)
                }
                InspectorSettingsDivider()
                serviceSettings
                InspectorSettingsDivider()
                InspectorSettingRow("Проверять IPv6") {
                    toggle("Проверять IPv6", config.checkIPv6) { value in model.update { $0.checkIPv6 = value } }
                        .help("Замораживать приложения, если IPv6 выходит мимо VPN.")
                }
            }

            disclosure("DNS и маршруты до ИИ-сервисов") {
                InspectorSettingsGroup {
                    InspectorSettingRow("Проверка DNS") {
                        Picker("Проверка DNS", selection: Binding(get: { model.config.dnsCheck },
                                                                  set: { value in model.update { $0.dnsCheck = value } })) {
                            Text("Предупреждать").tag(DNSCheckMode.warn)
                            Text("Замораживать").tag(DNSCheckMode.block)
                            Text("Выключена").tag(DNSCheckMode.off)
                        }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                    }
                    if config.dnsCheck == .block {
                        Note("У корпоративных VPN возможны ложные срабатывания.",
                             symbol: "info.circle", color: theme.palette.frozen)
                            .padding(.horizontal, theme.padding).padding(.bottom, theme.rowPadding)
                    }
                    InspectorSettingsDivider()
                    InspectorSettingRow("Маршрут до ИИ-сервисов",
                                        detail: "Проверяет, какой IP видят Claude, ChatGPT, Codex и Perplexity.") {
                        toggle("Маршрут до ИИ-сервисов", config.routeCheck) { value in
                            model.update { $0.routeCheck = value }
                        }
                    }
                }
            }
        }
    }

    private var serviceSettings: some View {
        DisclosureGroup {
            ForEach(IPServiceSet.ipv4Hosts, id: \.self) { host in
                let config = model.config
                let enabled = config.ipServices.contains(host)
                InspectorSettingRow(host) {
                    toggle(host, enabled) { on in
                        model.update { settings in
                            if on {
                                if !settings.ipServices.contains(host) {
                                    settings.ipServices.append(host)
                                }
                            } else if settings.ipServices.count > settings.minAgree {
                                settings.ipServices.removeAll { $0 == host }
                            }
                        }
                    }
                    .disabled(enabled && config.ipServices.count <= config.minAgree)
                }
            }
        } label: {
            HStack {
                Text("Сервисы внешнего IP").font(theme.font(12, weight: .medium)).foregroundColor(theme.palette.text.swiftUIColor)
                Spacer(minLength: theme.smallGap)
                Text("Включено \(model.config.ipServices.count)")
                    .font(theme.font(11)).foregroundColor(theme.palette.muted.swiftUIColor)
            }
            .padding(.vertical, theme.rowPadding + 6)
        }
        .tint(theme.palette.muted.swiftUIColor)
        .padding(.horizontal, theme.padding)
    }

    private func disclosure<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        DisclosureGroup {
            content().padding(.top, theme.smallGap)
        } label: {
            Text(title).font(theme.font(11)).foregroundColor(theme.palette.muted.swiftUIColor)
        }
        .tint(theme.palette.muted.swiftUIColor)
    }

    private func toggle(_ label: String, _ on: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        Toggle(label, isOn: Binding(get: { on }, set: set))
            .toggleStyle(SNSwitchStyle(theme: theme, showLabel: false)).fixedSize()
            .accessibilityLabel(label)
    }

    private func durationRow(_ title: String, _ key: WritableKeyPath<Config, TimeInterval>,
                             _ range: ClosedRange<Double>, unit: DurationInput.Unit = .seconds,
                             detail: String? = nil) -> some View {
        let setting = InspectorDurationSetting(key: key, range: range, unit: unit)
        return InspectorDurationRow(title: title, value: setting.value(in: model.config), range: range,
                                    unit: unit, detail: detail) { number in
            model.update { setting.set(number, in: &$0) }
        } step: { amount in
            model.update { setting.step(by: amount, in: &$0) }
        }
    }
}
