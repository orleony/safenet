import SwiftUI
import SafeNetCore

/// "Приложения": ready-made presets, browsers for AI, own apps, per-app rules.
struct AppsTab: View {
    @ObservedObject var model: AppState
    @EnvironmentObject var theme: Theme
    @State private var expanded: String?
    @State private var editingCustom: String?
    @State private var addingCustom = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing + 2) {
            SectionHeader(title: "Защищаемые приложения",
                          subtitle: "Включённые приложения замораживаются, когда IP или страна не из разрешённых, и закрываются, если за срок заморозки правильный адрес не вернулся. Вспомогательные процессы замораживаются вместе с приложением.")
            group("ИИ-приложения", AppCatalog.presets.filter { $0.group == AppCatalog.aiApps })
            group("Другие", AppCatalog.presets.filter { $0.group == nil })
            group("Браузеры для ИИ", AppCatalog.presets.filter { $0.group == AppCatalog.browsersForAI },
                  note: "Браузер замораживается целиком, со всеми вкладками.")
            if !unknownIDs.isEmpty { unknownCard }
            customCard
        }
    }

    private func group(_ title: String, _ presets: [AppCatalog.Preset], note: String? = nil) -> some View {
        Card {
            Text(title).font(theme.font(12, weight: .semibold)).foregroundColor(theme.palette.text.swiftUIColor)
            if let n = note { Note(n) }
            ForEach(presets, id: \.id) { pr in
                PresetRow(model: model, preset: pr, expanded: $expanded)
            }
        }
    }

    /// Saved ids that are neither presets nor custom apps (hand-edited config): matched by nothing.
    private var unknownIDs: [String] {
        model.config.apps.filter { id in AppCatalog.preset(id) == nil && !model.config.customApps.contains { $0.name == id } }
    }

    private var unknownCard: some View {
        Card {
            Text("Неизвестные записи").font(theme.font(12, weight: .semibold)).foregroundColor(theme.palette.text.swiftUIColor)
            Note("Эти названия есть в config.yaml, но такого готового набора нет: они ничего не защищают. Добавьте своё приложение с правилом или уберите запись.",
                 symbol: "exclamationmark.triangle", color: theme.palette.frozen)
            ForEach(unknownIDs, id: \.self) { id in
                RemovableRow(title: id, detail: "не защищается", removeLabel: "Убрать \(id) из списка") {
                    model.update { $0.apps.removeAll { $0 == id } }
                }
            }
        }
    }

    private var customCard: some View {
        let p = theme.palette
        return Card {
            HStack {
                Text("Свои приложения").font(theme.font(12, weight: .semibold)).foregroundColor(p.text.swiftUIColor)
                Spacer()
                if !addingCustom {
                    Button("Добавить") { addingCustom = true; editingCustom = nil }
                        .buttonStyle(SNButtonStyle(kind: .secondary, theme: theme)).fixedSize()
                }
            }
            Note("Сопоставление: имя процесса (Telegram), часть пути со слешем (/MyApp.app/), часть командной строки (args:bot.py), имя команды (cmd:claude); условия можно объединять через && (node && args:bot.js).")
            if addingCustom {
                CustomAppEditor(model: model, original: nil) { addingCustom = false }
            }
            if model.config.customApps.isEmpty && !addingCustom { Note("Своих приложений пока нет") }
            ForEach(model.config.customApps, id: \.name) { app in
                if editingCustom == app.name {
                    CustomAppEditor(model: model, original: app) { editingCustom = nil }
                } else {
                    CustomRow(model: model, app: app, expanded: $expanded, edit: { editingCustom = app.name; addingCustom = false })
                }
            }
        }
    }
}

/// App state badge: ЗАМОРОЖЕНО / НЕ ЗАМОРОЖЕНО / ОТПУЩЕНО / ЗАКРЫТО (only apps that were closed).
func appBadge(_ id: String, _ s: EngineStatus, _ p: Palette) -> (String, RGB)? {
    if s.freezeFailedApps.contains(id) { return ("НЕ ЗАМОРОЖЕНО", p.danger) }
    if s.frozenApps.contains(id) { return ("ЗАМОРОЖЕНО", p.frozen) }
    if s.closedApps.contains(id) { return ("ЗАКРЫТО", p.danger) }
    if s.releasedApps.contains(id) { return ("ОТПУЩЕНО", p.muted) }
    return nil
}

private struct PresetRow: View {
    @ObservedObject var model: AppState
    let preset: AppCatalog.Preset
    @Binding var expanded: String?
    @EnvironmentObject var theme: Theme

    var body: some View {
        let p = theme.palette
        let on = model.config.apps.contains { $0.caseInsensitiveCompare(preset.id) == .orderedSame }
        VStack(alignment: .leading, spacing: theme.smallGap) {
            HStack(spacing: theme.spacing - 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.name).font(theme.font(12, weight: .medium))
                        .foregroundColor((preset.unsupported == nil ? p.text : p.muted).swiftUIColor)
                    if let why = preset.unsupported {
                        Text("Не поддерживается: \(why)").font(theme.font(10)).foregroundColor(p.muted.swiftUIColor)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if on, let s = ruleSummary(preset.id, model.config) {
                        Text(s).font(theme.font(10)).foregroundColor(p.muted.swiftUIColor)
                    }
                }
                Spacer(minLength: theme.smallGap)
                if on, let b = appBadge(preset.id, model.status, p) { Badge(text: b.0, color: b.1) }
                if preset.unsupported != nil {
                    if on {
                        Button("Убрать") { model.update { $0.apps.removeAll { $0.caseInsensitiveCompare(preset.id) == .orderedSame } } }
                            .buttonStyle(SNButtonStyle(kind: .secondary, theme: theme)).fixedSize()
                            .accessibilityLabel("Убрать \(preset.name) из списка")
                    }
                } else {
                    if on {
                        Button(expanded == preset.id ? "Скрыть правила" : "Правила") {
                            expanded = expanded == preset.id ? nil : preset.id
                        }
                        .buttonStyle(.plain).font(theme.font(11)).foregroundColor(p.accent.swiftUIColor)
                        .accessibilityLabel("Правила для \(preset.name)")
                    }
                    Toggle(preset.name, isOn: Binding(get: { on }, set: { _ in model.toggleApp(preset.id) }))
                        .toggleStyle(SNSwitchStyle(theme: theme, showLabel: false)).fixedSize()
                        .accessibilityLabel("Защищать \(preset.name)")
                }
            }
            if on && expanded == preset.id && preset.unsupported == nil { AppRulesEditor(model: model, id: preset.id) }
        }
        .padding(.vertical, 2)
    }
}

/// "свои страны: NL, DE · заморозка 60 с" (nil when the app uses the common settings).
func ruleSummary(_ id: String, _ c: Config) -> String? {
    var parts: [String] = []
    if let r = c.appRules[id] {
        let list = r.countries.map { $0.uppercased() } + r.ips
        parts.append(list.isEmpty ? "свой список пуст — всегда заморожено" : "свои разрешения: " + list.joined(separator: ", "))
    }
    if let g = c.appGrace[id] { parts.append("заморозка \(DurationInput.text(g)) с") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

private struct CustomRow: View {
    @ObservedObject var model: AppState
    let app: CustomApp
    @Binding var expanded: String?
    let edit: () -> Void
    @EnvironmentObject var theme: Theme

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.smallGap) {
            HStack(spacing: theme.spacing - 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(theme.font(12, weight: .medium)).foregroundColor(p.text.swiftUIColor)
                    Text("\(app.match) — \(CustomAppInput.kindText(app.match))").font(theme.font(10, weight: .regular))
                        .foregroundColor(p.muted.swiftUIColor).fixedSize(horizontal: false, vertical: true)
                    if let s = ruleSummary(app.name, model.config) { Text(s).font(theme.font(10)).foregroundColor(p.muted.swiftUIColor) }
                }
                Spacer(minLength: theme.smallGap)
                if let b = appBadge(app.name, model.status, p) { Badge(text: b.0, color: b.1) }
                Button(expanded == app.name ? "Скрыть правила" : "Правила") { expanded = expanded == app.name ? nil : app.name }
                    .buttonStyle(.plain).font(theme.font(11)).foregroundColor(p.accent.swiftUIColor)
                    .accessibilityLabel("Правила для \(app.name)")
                Button("Изменить", action: edit)
                    .buttonStyle(.plain).font(theme.font(11)).foregroundColor(p.accent.swiftUIColor)
                    .accessibilityLabel("Изменить \(app.name)")
            }
            if expanded == app.name { AppRulesEditor(model: model, id: app.name) }
        }
        .padding(.vertical, 2)
    }
}
