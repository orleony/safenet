import SwiftUI
import SafeNetCore

/// Per-app rules: own allow list (REPLACES the common one) and own freeze time.
struct AppRulesEditor: View {
    @ObservedObject var model: AppState
    let id: String
    @EnvironmentObject var theme: Theme

    var body: some View {
        let c = model.config
        let ownList = c.appRules[id]
        VStack(alignment: .leading, spacing: theme.spacing - 2) {
            Toggle(isOn: Binding(get: { ownList == nil }, set: { v in model.update { ConfigEdit.setUseCommonRules(&$0, id, v) } })) {
                label("Общий список «Разрешено»", "Выключите, чтобы задать этому приложению свои страны и IP. Свой список ЗАМЕНЯЕТ общий, а не дополняет его.")
            }
            .toggleStyle(SNSwitchStyle(theme: theme))
            if let own = ownList {
                if own.ips.isEmpty && own.countries.isEmpty {
                    Note("Свой список пуст: приложение будет заморожено всегда.", symbol: "exclamationmark.triangle", color: theme.palette.frozen)
                }
                AllowListEditor(list: own) { m in
                    model.update { cfg in var l = cfg.appRules[id] ?? AllowList(); m(&l); cfg.appRules[id] = l }
                }
            }
            Toggle(isOn: Binding(get: { c.appGrace[id] == nil }, set: { v in model.update { ConfigEdit.setUseCommonGrace(&$0, id, v) } })) {
                label("Общее время заморозки (\(DurationInput.text(c.grace)) с)", "Выключите, чтобы задать своё время до закрытия.")
            }
            .toggleStyle(SNSwitchStyle(theme: theme))
            if let g = c.appGrace[id] {
                ValidatedField(label: "Своё время заморозки, секунд", placeholder: "секунд", actionTitle: "Сохранить",
                               initial: DurationInput.text(g), width: 120,
                               validate: { r in let x = DurationInput.parse(r, range: 5...3600); return InputCheck(value: x.value.map { DurationInput.text($0) }, error: x.error, warning: nil) },
                               commit: { v in if let d = DurationInput.parse(v, range: 5...3600).value { model.update { $0.appGrace[id] = d } } })
            }
        }
        .padding(theme.spacing - 2)
        .background(RoundedRectangle(cornerRadius: Metrics.smallCornerRadius).fill(theme.palette.background.swiftUIColor))
    }

    private func label(_ t: String, _ d: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(t).font(theme.font(12, weight: .medium)).foregroundColor(theme.palette.text.swiftUIColor)
            Text(d).font(theme.font(10)).foregroundColor(theme.palette.muted.swiftUIColor).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Add / edit / delete one custom app with validation (errors block saving, warnings do not).
struct CustomAppEditor: View {
    @ObservedObject var model: AppState
    let original: CustomApp?
    let done: () -> Void
    @EnvironmentObject var theme: Theme
    @State private var name = ""
    @State private var match = ""
    @State private var confirmDelete = false

    var body: some View {
        let p = theme.palette
        let r = CustomAppInput.check(name: name, match: match, config: model.config, editing: original?.name)
        let started = !name.isEmpty || !match.isEmpty
        VStack(alignment: .leading, spacing: theme.smallGap + 2) {
            field("Название", "Мой бот", $name)
            field("Правило", "Telegram, /MyApp.app/, args:bot.py", $match)
            if !match.trimmingCharacters(in: .whitespaces).isEmpty {
                Note("Сопоставление " + CustomAppInput.kindText(match))
            }
            if started { ForEach(r.errors, id: \.self) { Note($0, symbol: "xmark.octagon", color: p.danger) } }
            ForEach(r.warnings, id: \.self) { Note($0, symbol: "exclamationmark.triangle", color: p.frozen) }
            HStack(spacing: theme.spacing - 4) {
                Button("Сохранить") {
                    let o = original?.name, n = name, m = match
                    model.update { ConfigEdit.saveCustom(&$0, original: o, name: n, match: m) }
                    done()
                }
                .buttonStyle(SNButtonStyle(kind: .primary, theme: theme)).fixedSize()
                .disabled(!r.errors.isEmpty).opacity(r.errors.isEmpty ? 1 : 0.5)
                Button("Отмена", action: done).buttonStyle(SNButtonStyle(kind: .secondary, theme: theme)).fixedSize()
                Spacer()
                if let o = original {
                    Button("Удалить") { confirmDelete = true }
                        .buttonStyle(SNButtonStyle(kind: .danger, theme: theme)).fixedSize()
                        .confirmationDialog("Удалить «\(o.name)»?", isPresented: $confirmDelete) {
                            Button("Удалить", role: .destructive) { model.update { ConfigEdit.deleteCustom(&$0, o.name) }; done() }
                            Button("Отмена", role: .cancel) {}
                        } message: { Text("Приложение перестанет защищаться, его свои правила удалятся.") }
                }
            }
        }
        .padding(theme.spacing - 2)
        .background(RoundedRectangle(cornerRadius: Metrics.smallCornerRadius).fill(p.background.swiftUIColor))
        .onAppear { name = original?.name ?? ""; match = original?.match ?? "" }
    }

    private func field(_ label: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        HStack(spacing: theme.spacing - 4) {
            Text(label).font(theme.font(11)).foregroundColor(theme.palette.muted.swiftUIColor).frame(width: 70, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain).font(theme.font(12)).foregroundColor(theme.palette.text.swiftUIColor)
                .padding(.horizontal, theme.spacing - 4).padding(.vertical, theme.rowPadding)
                .background(RoundedRectangle(cornerRadius: Metrics.smallCornerRadius).fill(theme.palette.surface.swiftUIColor))
                .overlay(RoundedRectangle(cornerRadius: Metrics.smallCornerRadius).stroke(theme.palette.hairline.swiftUIColor, lineWidth: Metrics.hairlineWidth))
                .accessibilityLabel(label)
        }
    }
}
