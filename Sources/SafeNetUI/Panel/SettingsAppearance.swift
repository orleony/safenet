import SwiftUI
import SafeNetCore

/// Theme, accent (presets + own hex with live preview), density, font, menu bar.
struct AppearanceSettings: View {
    @ObservedObject var model: AppState
    @EnvironmentObject var theme: Theme
    @State private var hex = ""

    static let accents: [(String, String)] = [("blue", "Синий"), ("violet", "Фиолетовый"), ("orange", "Оранжевый"),
                                              ("pink", "Розовый"), ("neutral", "Нейтральный")]

    var body: some View {
        let p = theme.palette
        let c = model.config
        let current = AccentName(configValue: c.accent)
        let dark = p.background.luminance < 0.2
        Card {
            Text("Внешний вид").font(theme.font(12, weight: .semibold)).foregroundColor(p.text.swiftUIColor)
            SettingRow("Тема", detail: c.theme == .system ? "Меняется вместе с системой." : nil) {
                Segmented(options: [(ThemeChoice.light, "Светлая"), (.dark, "Тёмная"), (.system, "Как в системе")],
                          selection: c.theme) { v in model.update { $0.theme = v } }
            }
            SettingRow("Акцентный цвет", detail: "Цвет кнопок и выделения. Статусы всегда зелёный / оранжевый / красный.") {
                HStack(spacing: theme.smallGap) {
                    ForEach(AppearanceSettings.accents, id: \.0) { a in
                        let name = AccentName(configValue: a.0)
                        Button { model.update { $0.accent = a.0 } } label: {
                            ZStack {
                                Circle().fill(name.color(dark: dark).swiftUIColor).frame(width: 20, height: 20)
                                if name == current {
                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                                        .foregroundColor(onAccentColor(for: name.color(dark: dark)).swiftUIColor)
                                }
                            }
                            .overlay(Circle().stroke(p.hairline.swiftUIColor, lineWidth: Metrics.hairlineWidth))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(a.1)
                        .accessibilityAddTraits(name == current ? .isSelected : [])
                        .help(a.1)
                    }
                }
            }
            SettingRow("Свой цвет", detail: customDetail(current)) {
                HStack(spacing: theme.smallGap) {
                    let preview = RGB(hex: hex)
                    Circle().fill((preview ?? p.hairline).swiftUIColor).frame(width: 20, height: 20)
                        .overlay(Circle().stroke(p.hairline.swiftUIColor, lineWidth: Metrics.hairlineWidth))
                        .accessibilityHidden(true)
                    ValidatedField(label: "Свой цвет, #RRGGBB", placeholder: "#3366ff", actionTitle: "Применить", width: 90,
                                   draft: $hex,
                                   validate: { t in AccentInput.parse(t).map { .ok($0) } ?? .fail("Нужен цвет вида #3366ff") },
                                   commit: { v in model.update { $0.accent = v } })
                        .frame(width: 200)
                }
            }
            SettingRow("Плотность") {
                Segmented(options: [(Density.compact, "Компактная"), (.comfortable, "Просторная")], selection: c.density) { v in
                    model.update { $0.density = v }
                }
            }
            SettingRow("Шрифт") {
                Segmented(options: [(FontStyle.system, "Системный"), (.mono, "Моноширинный")], selection: c.fontStyle) { v in
                    model.update { $0.fontStyle = v }
                }
            }
            SettingRow("Строка меню", detail: "Что показывать рядом со значком в строке меню.") {
                Segmented(options: [(MenubarDisplay.ip, "IP"), (.country, "Страна"), (.icon, "Только значок")], selection: c.menubar) { v in
                    model.update { $0.menubar = v }
                }
            }
        }
    }

    private func customDetail(_ a: AccentName) -> String {
        if case .custom(let h) = a { return "Сейчас: \(h). Слишком светлый или тёмный цвет может плохо читаться." }
        return "Любой цвет в формате #RRGGBB; кружок слева показывает его сразу."
    }
}

/// Autostart, config file, about (version, leak window, privacy).
struct SystemSettings: View {
    @ObservedObject var model: AppState
    @EnvironmentObject var theme: Theme

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.spacing + 2) {
            Card {
                Text("Система").font(theme.font(12, weight: .semibold)).foregroundColor(p.text.swiftUIColor)
                SettingRow("Запускать при входе в систему", detail: Autostart.isAvailable ? nil : "Работает только из SafeNet.app.") {
                    Toggle("Запускать при входе в систему", isOn: Binding(get: { model.autostartEnabled }, set: { model.setAutostart($0) }))
                        .toggleStyle(SNSwitchStyle(theme: theme, showLabel: false)).fixedSize()
                        .accessibilityLabel("Запускать при входе в систему")
                }
                if let e = model.autostartError { Note(e, symbol: "xmark.octagon", color: p.danger) }
                if model.autostartState == .requiresApproval {
                    Note("Автозапуск требует подтверждения в Системных настройках → «Основные» → «Объекты входа»: пока его не разрешить, SafeNet при входе не запустится.",
                         symbol: "exclamationmark.triangle", color: p.frozen)
                    Button("Открыть «Объекты входа»") { model.openLoginItemsSettings() }
                        .buttonStyle(SNButtonStyle(kind: .secondary, theme: theme)).fixedSize()
                }
                SettingRow("Файл настроек", detail: "config.yaml в ~/Library/Application Support/SafeNet") {
                    Button("Показать файл настроек") { model.revealConfig() }
                        .buttonStyle(SNButtonStyle(kind: .secondary, theme: theme)).fixedSize()
                        .disabled(model.configURL == nil)
                }
            }
            Card {
                Text("О программе").font(theme.font(12, weight: .semibold)).foregroundColor(p.text.swiftUIColor)
                Text("SafeNet, версия \(AppState.version)").font(theme.font(12)).foregroundColor(p.text.swiftUIColor)
                Note("Окно утечки. На события сети (VPN отключился, сменился интерфейс или маршрут) SafeNet реагирует за десятки–сотни миллисекунд. Но если IP меняется «тихо» — например, VPN переключил сервер без смены интерфейса, — это заметит только опрос, то есть в пределах интервала проверки (сейчас \(DurationInput.text(model.config.checkInterval)) с). SafeNet дополняет, а не заменяет kill switch самого VPN: включите и его.")
                Note("Приватность. Наружу уходят только запросы к IP-сервисам (каждые 5 с — Cloudflare 1.1.1.1 и api.country.is; полная проверка с ipinfo.io, ipapi.co, ifconfig.co, v6.ident.me — при смене сети, по кнопке и раз в 10 минут) и к /cdn-cgi/trace пяти ИИ-сервисов. Никакой телеметрии, аналитики и обновлений; настройки и журнал остаются на этом Mac.")
            }
        }
        .onAppear { model.refreshAutostart() }
    }
}
