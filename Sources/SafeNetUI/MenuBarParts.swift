import SwiftUI
import SafeNetCore

/// Button look for the menu window. Colours come from the Theme palette only.
struct SNButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger }
    let kind: Kind
    let theme: Theme

    func makeBody(configuration: Configuration) -> some View {
        GlassButton(kind: kind, theme: theme, configuration: configuration)
    }
}

/// Capsule button with a translucent tint over the window's glass: accent (primary), ink
/// (secondary) or red (danger). Brightens on hover, deepens while pressed, fades when disabled.
private struct GlassButton: View {
    let kind: SNButtonStyle.Kind
    let theme: Theme
    let configuration: ButtonStyleConfiguration
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let p = theme.palette
        let tint: RGB, ink: RGB, base: Double
        switch kind {
        case .primary: tint = p.accent; ink = p.accent; base = Metrics.accentFill
        case .secondary: tint = p.text; ink = p.text; base = Metrics.neutralFill
        case .danger: tint = p.danger; ink = p.danger; base = Metrics.neutralFill * 1.8
        }
        let boost = configuration.isPressed ? 1.7 : (hover && enabled ? 1.35 : 1)
        return configuration.label
            .font(theme.font(12, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundColor(ink.swiftUIColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, theme.rowPadding + 1)
            .padding(.horizontal, theme.spacing)
            .background(Capsule().fill(tint.swiftUIColor.opacity(min(0.6, base * boost))))
            .overlay(Capsule().strokeBorder(tint.swiftUIColor.opacity(Metrics.tintStroke + (hover && enabled ? 0.08 : 0)),
                                            lineWidth: Metrics.hairlineWidth))
            .opacity(enabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: hover)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .contentShape(Capsule())
            .onHover { hover = $0 }
    }
}

/// Behind-window blur (NSVisualEffectView): the menu window and the panel sidebar sit on it.
struct GlassBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

struct Hairline: View {
    @EnvironmentObject var theme: Theme
    var body: some View {
        Rectangle().fill(theme.palette.text.swiftUIColor.opacity(theme.isDark ? 0.09 : 0.08)).frame(height: Metrics.hairlineWidth)
    }
}

/// Small capsule label (test mode, app state badges): tinted fill, sentence case.
struct Badge: View {
    @EnvironmentObject var theme: Theme
    let text: String
    let color: RGB
    var body: some View {
        Text(text)
            .font(theme.font(10, weight: .semibold))
            .foregroundColor(color.swiftUIColor)
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(Capsule().fill(color.swiftUIColor.opacity(0.14)))
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
        case .ipv6Leak, .dnsLeak, .routeLeak, .freezeFailed, .vpnDown: return p.danger
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
        if s.unprotectableApps.contains(id) { return ("Системное, не защищается", p.danger) }
        if s.freezeFailedApps.contains(id) { return ("Не заморожено", p.danger) }
        if s.notRunningApps.contains(id) { return ("Не запущено", p.muted) }
        if s.frozenApps.contains(id) { return ("Заморожено", p.frozen) }
        if s.releasedApps.contains(id) { return ("Отпущено", p.muted) }
        if s.closedApps.contains(id) { return ("Закрыто", p.danger) }
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
                        .font(theme.display(20))
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
        .padding(theme.spacing)
        .background(TintedGlass(color: stateColor(model.state, p), theme: theme))
    }
}

/// Card tinted with a state colour (frozen, first run): faint fill, faint edge.
struct TintedGlass: View {
    let color: RGB
    let theme: Theme
    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
            .fill(color.swiftUIColor.opacity(theme.isDark ? 0.10 : 0.08))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .strokeBorder(color.swiftUIColor.opacity(0.18), lineWidth: Metrics.hairlineWidth))
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
        .padding(theme.spacing)
        .background(TintedGlass(color: p.accent, theme: theme))
    }
}
