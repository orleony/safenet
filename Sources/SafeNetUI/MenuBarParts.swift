import SwiftUI
import SafeNetCore

/// Button look for the menu window. Colours come from the Theme palette only.
struct SNButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger }
    let kind: Kind
    let theme: Theme

    func makeBody(configuration: Configuration) -> some View {
        let p = theme.palette
        let fill: Color, ink: Color
        switch kind {
        case .primary: fill = p.accent.swiftUIColor; ink = p.onAccent.swiftUIColor
        case .secondary: fill = p.surface.swiftUIColor; ink = p.text.swiftUIColor
        case .danger: fill = p.surface.swiftUIColor; ink = p.danger.swiftUIColor
        }
        return configuration.label
            .font(theme.font(12, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.9)
            .foregroundColor(ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, theme.rowPadding)
            .padding(.horizontal, theme.smallGap)
            .background(RoundedRectangle(cornerRadius: Metrics.smallCornerRadius).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: Metrics.smallCornerRadius)
                .stroke(p.hairline.swiftUIColor, lineWidth: kind == .primary ? 0 : Metrics.hairlineWidth))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

struct Hairline: View {
    @EnvironmentObject var theme: Theme
    var body: some View {
        Rectangle().fill(theme.palette.hairline.swiftUIColor).frame(height: Metrics.hairlineWidth)
    }
}

/// Small rounded label ("ТЕСТОВЫЙ РЕЖИМ", app state badges).
struct Badge: View {
    @EnvironmentObject var theme: Theme
    let text: String
    let color: RGB
    var body: some View {
        Text(text)
            .font(theme.font(9, weight: .bold))
            .foregroundColor(color.swiftUIColor)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).stroke(color.swiftUIColor, lineWidth: Metrics.hairlineWidth))
            .lineLimit(1)
    }
}

/// State colour: ok green, frozen orange, closed / leak / failed freeze red, paused grey.
func stateColor(_ s: GuardState, _ p: Palette) -> RGB {
    switch s {
    case .ok: return p.ok
    case .paused: return p.muted
    case .closed: return p.danger
    case .frozen(_, let r, _):
        switch r {
        case .ipv6Leak, .dnsLeak, .routeLeak, .freezeFailed: return p.danger
        default: return p.frozen
        }
    }
}

/// One protected app: name, state badge, toggle (presets) or "своё правило" (custom apps).
struct AppRow: View {
    @EnvironmentObject var theme: Theme
    @ObservedObject var model: AppState
    let id: String

    var body: some View {
        let p = theme.palette
        HStack(spacing: theme.smallGap) {
            VStack(alignment: .leading, spacing: 1) {
                Text(AppCatalog.displayName(for: id))
                    .font(theme.font(12, weight: .medium))
                    .foregroundColor(p.text.swiftUIColor)
                    .lineLimit(1)
                if let note = unsupportedNote {
                    Text(note).font(theme.font(10)).foregroundColor(p.muted.swiftUIColor).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if let b = badge { Badge(text: b.0, color: b.1) }
            if isCustom {
                Text("своё").font(theme.font(10)).foregroundColor(p.muted.swiftUIColor)
            } else {
                Toggle(AppCatalog.displayName(for: id), isOn: Binding(get: { model.config.apps.contains(id) }, set: { _ in model.toggleApp(id) }))
                    .toggleStyle(SNSwitchStyle(theme: theme, showLabel: false))
                    .fixedSize()
                    .accessibilityLabel("Защищать \(AppCatalog.displayName(for: id))")
            }
        }
    }

    private var isCustom: Bool { model.config.customApps.contains { $0.name == id } }

    private var unsupportedNote: String? {
        guard !isCustom, let pr = AppCatalog.preset(id), let why = pr.unsupported else { return nil }
        // Menu is narrow: the reason's first clause; the panel shows it in full.
        return "не поддерживается: " + (why.split(separator: ":").first.map(String.init) ?? why)
    }

    private var badge: (String, RGB)? {
        let p = theme.palette, s = model.status
        guard AppCatalog.appIDs(in: model.config).contains(id) else { return nil }
        if s.unprotectableApps.contains(id) { return ("СИСТЕМНОЕ — НЕ ЗАЩИЩАЕТСЯ", p.danger) }
        if s.freezeFailedApps.contains(id) { return ("НЕ ЗАМОРОЖЕНО", p.danger) }
        if s.notRunningApps.contains(id) { return ("НЕ ЗАПУЩЕНО", p.muted) }
        if s.frozenApps.contains(id) { return ("ЗАМОРОЖЕНО", p.frozen) }
        if s.releasedApps.contains(id) { return ("ОТПУЩЕНО", p.muted) }
        if s.closedApps.contains(id) { return ("ЗАКРЫТО", p.danger) }
        return nil
    }
}

/// Orange block for the frozen state: reason, countdown, actions.
struct FrozenCard: View {
    @EnvironmentObject var theme: Theme
    @ObservedObject var model: AppState
    let reason: Reason
    let deadline: Date?
    @State private var confirmClose = false

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.smallGap) {
            Text(Format.reason(reason).prefix(1).uppercased() + Format.reason(reason).dropFirst())
                .font(theme.font(12, weight: .medium))
                .foregroundColor(stateColor(model.state, p).swiftUIColor)
                .fixedSize(horizontal: false, vertical: true)
            if let d = deadline {
                TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                    Text("\(model.config.onTimeout == .close ? "Закрытие через" : "Срок заморозки") \(Format.countdown(d.timeIntervalSince(ctx.date)))")
                        .font(theme.font(18, weight: .semibold).monospacedDigit())
                        .foregroundColor(p.text.swiftUIColor)
                }
            } else {
                Text(reason == .offline ? "Без сети приложения не закрываются" : "Ждёт следующей проверки")
                    .font(theme.font(11)).foregroundColor(p.muted.swiftUIColor)
            }
            Button("Разрешить этот IP") { model.allowCurrent() }
                .buttonStyle(SNButtonStyle(kind: .secondary, theme: theme))
                .disabled(model.lastIP == nil)
            HStack(spacing: theme.smallGap) {
                Button("Продлить") { model.extend(by: 60) }
                    .buttonStyle(SNButtonStyle(kind: .secondary, theme: theme))
                    .disabled(deadline == nil)
                // Destructive: inline two-step confirmation (dialogs are unreliable in a menu window).
                Button(confirmClose ? "Точно закрыть?" : "Закрыть сейчас") {
                    if confirmClose { confirmClose = false; model.closeNow() } else {
                        confirmClose = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { confirmClose = false }
                    }
                }
                .buttonStyle(SNButtonStyle(kind: .danger, theme: theme))
            }
        }
        .padding(theme.spacing - 2)
        .background(RoundedRectangle(cornerRadius: Metrics.cornerRadius).fill(p.surface.swiftUIColor))
    }
}

/// First run: selected apps but nothing allowed -> they would stay frozen. Nothing is auto-allowed.
struct FirstRunCard: View {
    @EnvironmentObject var theme: Theme
    @ObservedObject var model: AppState
    let openPanel: () -> Void

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.smallGap) {
            Text("Выберите разрешённые страны или IP")
                .font(theme.font(12, weight: .semibold)).foregroundColor(p.text.swiftUIColor)
            Text("Пока список пуст, выбранные приложения заморожены (но не закрываются), пока вы не укажете разрешённую страну или IP.")
                .font(theme.font(11)).foregroundColor(p.muted.swiftUIColor)
                .fixedSize(horizontal: false, vertical: true)
            if let a = model.lastIP {
                Button("Разрешить текущую страну: \(Format.flag(a.country)) \(Format.countryName(a.country))") { model.allowCurrentCountry() }
                    .buttonStyle(SNButtonStyle(kind: .primary, theme: theme))
            }
            Button("Открыть панель") { openPanel() }
                .buttonStyle(SNButtonStyle(kind: .secondary, theme: theme))
        }
        .padding(theme.spacing - 2)
        .background(RoundedRectangle(cornerRadius: Metrics.cornerRadius).fill(p.surface.swiftUIColor))
    }
}
