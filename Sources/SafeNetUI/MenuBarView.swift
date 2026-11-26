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
        VStack(alignment: .leading, spacing: theme.spacing) {
            header
                .onAppear { PanelOpener.register(openWindow) }
            ipBlock
            notices
            Hairline()
            buttons
        }
        .padding(theme.padding + 6)
        .frame(width: 310)
        .background(theme.palette.background.swiftUIColor)
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
        return HStack(spacing: theme.smallGap) {
            Circle().fill(stateColor(model.state, p).swiftUIColor).frame(width: 8, height: 8)
            Text(Format.stateTitle(model.state, hasApps: model.hasProtectedApps))
                .font(theme.font(13, weight: .semibold)).foregroundColor(p.text.swiftUIColor)
            Spacer(minLength: 4)
            Button(action: model.quit) {
                Image(systemName: "power").frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundColor(p.muted.swiftUIColor)
            .help("Выйти из SafeNet")
            .accessibilityLabel("Выйти из SafeNet")
        }
    }

    private var ipBlock: some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: theme.smallGap / 2) {
            if let a = model.lastIP {
                Text(a.ip)
                    .font(theme.font(26, weight: .medium)).monospacedDigit()
                    .foregroundColor(p.text.swiftUIColor)
                    .lineLimit(1).minimumScaleFactor(0.55).textSelection(.enabled)
            } else if let country = model.status.sharedCountry {
                Text("\(Format.flag(country)) \(country) · несколько IP")
                    .font(theme.font(15, weight: .semibold)).foregroundColor(p.text.swiftUIColor)
            } else {
                Text(model.status.snapshot?.online == false ? "Нет сети" : (model.status.lastCheck == nil ? "Проверка…" : "IP не подтверждён"))
                    .font(theme.font(18, weight: .semibold)).foregroundColor(p.muted.swiftUIColor)
            }
            Text(networkLine).font(theme.font(11)).foregroundColor(p.muted.swiftUIColor).lineLimit(2)
        }
    }

    private var buttons: some View {
        HStack(spacing: theme.spacing - 4) {
            if case .paused(let until?) = model.state {
                TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                    Button("Возобновить · \(Format.countdown(until.timeIntervalSince(ctx.date)))") { model.resumeProtection() }
                        .buttonStyle(SNButtonStyle(kind: .secondary, theme: theme))
                }
            } else if case .paused = model.state {
                Button("Возобновить защиту") { model.resumeProtection() }
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
                .padding(.vertical, theme.rowPadding)
                .background(RoundedRectangle(cornerRadius: Metrics.smallCornerRadius).fill(theme.palette.surface.swiftUIColor))
                .overlay(RoundedRectangle(cornerRadius: Metrics.smallCornerRadius)
                    .stroke(theme.palette.hairline.swiftUIColor, lineWidth: Metrics.hairlineWidth))
            }
            Button("Открыть панель") { openPanel() }
                .buttonStyle(SNButtonStyle(kind: .primary, theme: theme))
        }
    }

    // MARK: Text

    /// "Нидерланды · VPN: активен · IPv6 чисто"
    private var networkLine: String {
        var parts: [String] = []
        if let a = model.lastIP { parts.append(Format.countryName(a.country)) }
        if let s = model.snapshot { parts.append(s.hasTunnel ? "VPN: активен" : "VPN: нет") }
        if model.config.checkIPv6 {
            parts.append(model.status.observation?.ipv6Leak == true ? "утечка IPv6" : "IPv6 чисто")
        }
        return parts.joined(separator: " · ")
    }

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
