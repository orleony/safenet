import SwiftUI
import AppKit
import SafeNetCore

/// Compact network status and protection actions. App selection lives in the panel.
public struct MenuBarView: View {
    @ObservedObject var model: AppState
    @EnvironmentObject var theme: Theme
    @Environment(\.openWindow) private var openWindow

    public init(model: AppState) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing + 2) {
            header
                .onAppear { PanelOpener.register(openWindow) }
            ipBlock
            notices
            buttons
        }
        .padding(theme.padding + 4)
        .frame(width: 300)
        .background(
            ZStack {
                GlassBackground(material: .popover)
                theme.palette.background.swiftUIColor.opacity(theme.isDark ? 0.55 : 0.45)
            }
        )
    }

    // MARK: Sections

    private var notices: some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: theme.spacing) {
            if model.testMode != nil {
                Text(model.configReadOnly
                     ? "Подставной IP вместо проверки. Настройки не сохраняются."
                     : "Подставной IP вместо проверки (SAFENET_FAKE_IP).")
                    .font(theme.font(11, weight: .medium)).foregroundColor(p.frozen.swiftUIColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle")
                    .font(theme.font(11)).foregroundColor(p.frozen.swiftUIColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.messages, id: \.text) { m in
                Label(m.text, systemImage: m.isError ? "xmark.octagon" : "info.circle")
                    .font(theme.font(11)).foregroundColor((m.isError ? p.danger : p.muted).swiftUIColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let u = UpdateText.menuLine(model.updateState) {
                HStack(spacing: theme.smallGap) {
                    Label(u, systemImage: "arrow.down.circle")
                        .font(theme.font(11)).foregroundColor(p.accent.swiftUIColor)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .available = model.updateState {
                        Spacer(minLength: 4)
                        Button("Обновить") { model.installUpdate() }
                            .buttonStyle(SNButtonStyle(kind: .secondary, theme: theme)).fixedSize()
                    }
                }
            }
            if model.needsAllowSetup { FirstRunCard(model: model, openPanel: openPanel) }
            if case .frozen(_, let r, let d) = model.state { FrozenCard(model: model, reason: r, deadline: d) }
            if case .closed(let at) = model.state {
                Text("Закрыты в \(at.formatted(date: .omitted, time: .shortened)); вернутся под защиту после успешной проверки")
                    .font(theme.font(11)).foregroundColor(p.danger.swiftUIColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var header: some View {
        let p = theme.palette
        return HStack(spacing: theme.spacing - 2) {
            AppMark(size: 26, state: stateColor(model.state, p), ring: p.background.swiftUIColor)
            if case .paused(let until?) = model.state {
                TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                    Text("Пауза, ещё \(Format.countdown(until.timeIntervalSince(ctx.date)))")
                        .font(theme.display(13)).foregroundColor(p.text.swiftUIColor)
                }
            } else {
                Text(Format.stateTitle(model.state, hasApps: model.hasProtectedApps))
                    .font(theme.display(13)).foregroundColor(p.text.swiftUIColor)
            }
            if model.testMode != nil { Badge(text: "Тест", color: p.frozen) }
            Spacer(minLength: 4)
            Button(action: model.quit) {
                Image(systemName: "power").font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(p.text.swiftUIColor.opacity(Metrics.neutralFill)))
            }
            .buttonStyle(.plain)
            .foregroundColor(p.muted.swiftUIColor)
            .help("Выйти из SafeNet")
            .accessibilityLabel("Выйти из SafeNet")
        }
    }

    private var ipBlock: some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: theme.smallGap + 2) {
            if let a = model.lastIP {
                Text(a.ip)
                    .font(theme.display(30))
                    .foregroundColor(p.text.swiftUIColor)
                    .lineLimit(1).minimumScaleFactor(0.55).textSelection(.enabled)
            } else if let country = model.status.sharedCountry {
                Text("\(Format.flag(country)) \(Format.countryName(country)), несколько IP")
                    .font(theme.display(17)).foregroundColor(p.text.swiftUIColor)
            } else {
                Text(model.status.snapshot?.online == false ? "Нет сети" : (model.status.lastCheck == nil ? "Проверка…" : "IP не подтверждён"))
                    .font(theme.display(20)).foregroundColor(p.muted.swiftUIColor)
            }
            NetworkFacts(model: model)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, theme.smallGap)
        .background(StateHalo(color: stateColor(model.state, p)))
    }

    private var buttons: some View {
        HStack(spacing: theme.spacing - 4) {
            if case .paused = model.state {
                Button("Возобновить") { model.resumeProtection() }
                    .buttonStyle(SNButtonStyle(kind: .secondary, theme: theme))
            } else {
                Menu {
                    Button("\(Int(model.defaultPause / 60)) мин (по умолчанию)") { model.pause() }
                    Button("5 мин") { model.pause(for: 5 * 60) }
                    Button("15 мин") { model.pause(for: 15 * 60) }
                    Button("1 час") { model.pause(for: 60 * 60) }
                    Button("До перезапуска") { model.pauseUntilRestart() }
                } label: {
                    Text("Пауза").font(theme.font(12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(maxWidth: .infinity)
                .padding(.vertical, theme.rowPadding + 1)
                .background(Capsule().fill(theme.palette.text.swiftUIColor.opacity(Metrics.neutralFill)))
                .overlay(Capsule().strokeBorder(theme.palette.text.swiftUIColor.opacity(Metrics.tintStroke),
                                                lineWidth: Metrics.hairlineWidth))
            }
            Button("Открыть панель") { openPanel() }
                .buttonStyle(SNButtonStyle(kind: .primary, theme: theme))
        }
    }

    // MARK: Text

    private var warnings: [String] {
        var w: [String] = []
        let s = model.status
        if let pw = model.proxyWarning { w.append(pw) }
        if s.dnsUnknown { w.append("DNS: нет данных о серверах, утечку проверить нельзя") }
        if model.config.dnsCheck == .warn, s.observation?.dnsLeak == true { w.append("Возможна утечка DNS мимо VPN") }
        if model.status.observation?.trustedNetwork == true { w.append("Доверенная сеть: VPN не требуется") }
        return w
    }

    private func openPanel() { PanelOpener.open(openWindow) }
}

/// Country, tunnel and IPv6 under the IP: three small facts, each with its own symbol.
struct NetworkFacts: View {
    @ObservedObject var model: AppState
    @EnvironmentObject var theme: Theme

    var body: some View {
        let p = theme.palette
        HStack(spacing: theme.spacing) {
            if let a = model.lastIP {
                fact(Text(Format.flag(a.country)), Format.countryName(a.country), p.muted)
            }
            if let s = model.snapshot {
                fact(Image(systemName: s.hasTunnel ? "lock.fill" : "lock.open"), s.hasTunnel ? "VPN" : "Без VPN",
                     s.hasTunnel ? p.muted : p.frozen)
            }
            if model.config.checkIPv6 {
                let leak = model.status.observation?.ipv6Leak == true
                fact(Image(systemName: leak ? "exclamationmark.triangle.fill" : "checkmark"), leak ? "Утечка IPv6" : "IPv6",
                     leak ? p.danger : p.muted)
            }
        }
        .font(theme.font(11, weight: .medium))
        .lineLimit(1)
    }

    private func fact<I: View>(_ icon: I, _ text: String, _ color: RGB) -> some View {
        HStack(spacing: 4) {
            icon.font(.system(size: 10, weight: .semibold))
            Text(text)
        }
        .foregroundColor(color.swiftUIColor)
    }
}

/// State dot with a soft glow of the same colour.
struct StatusDot: View {
    let color: RGB
    var body: some View {
        Circle().fill(color.swiftUIColor).frame(width: 8, height: 8)
            .background(Circle().fill(RadialGradient(colors: [color.swiftUIColor.opacity(0.45), color.swiftUIColor.opacity(0)],
                                                     center: .center, startRadius: 3, endRadius: 9))
                .frame(width: 18, height: 18))
            .accessibilityHidden(true)
    }
}

/// The one loud element: a soft wash of the state colour behind the IP address. An elliptical
/// gradient that reaches zero at its own edge, so it never shows a border.
struct StateHalo: View {
    let color: RGB
    var body: some View {
        EllipticalGradient(stops: [.init(color: color.swiftUIColor.opacity(0.24), location: 0),
                                   .init(color: color.swiftUIColor.opacity(0.10), location: 0.45),
                                   .init(color: color.swiftUIColor.opacity(0), location: 1)],
                           center: UnitPoint(x: 0.3, y: 0.5), startRadiusFraction: 0, endRadiusFraction: 0.5)
            .padding(.horizontal, -40).padding(.vertical, -30)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
