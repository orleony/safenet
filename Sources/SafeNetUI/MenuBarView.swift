import SwiftUI
import AppKit
import SafeNetCore

/// Menu-bar window, style "A · Тёмное стекло" (~270 pt): state, flag + IP, network line,
/// warnings, first-run / frozen blocks, protected apps, "Пауза" and "Панель →".
public struct MenuBarView: View {
    @ObservedObject var model: AppState
    @EnvironmentObject var theme: Theme
    @Environment(\.openWindow) private var openWindow

    public init(model: AppState) { self.model = model }

    public var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.spacing) {
            header
            ipBlock
            notices
            Hairline()
            apps
            Hairline()
            buttons
            HStack {
                Spacer()
                Button("Выйти из SafeNet") { model.quit() }
                    .buttonStyle(.plain)
                    .font(theme.font(10))
                    .foregroundColor(p.muted.swiftUIColor)
            }
        }
        .padding(14)
        .frame(width: 270)
        .background(p.background.swiftUIColor)
    }

    // MARK: Sections

    private var notices: some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: theme.spacing) {
            ForEach(warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle")
                    .font(theme.font(11)).foregroundColor(p.frozen.swiftUIColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let e = model.lastError {
                Text(e).font(theme.font(11)).foregroundColor(p.danger.swiftUIColor)
                    .fixedSize(horizontal: false, vertical: true)
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
        return HStack(spacing: 6) {
            Circle().fill(stateColor(model.state, p).swiftUIColor).frame(width: 8, height: 8)
            Text(Format.stateTitle(model.state, hasApps: model.hasProtectedApps))
                .font(theme.font(13, weight: .semibold)).foregroundColor(p.text.swiftUIColor)
            Spacer(minLength: 4)
            if model.testMode != nil { Badge(text: "ТЕСТОВЫЙ РЕЖИМ", color: p.frozen) }
        }
    }

    private var ipBlock: some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 2) {
            if let a = model.lastIP {
                HStack(spacing: 8) {
                    Text(Format.flag(a.country)).font(.system(size: 26))
                    Text(a.ip).font(theme.font(20, weight: .semibold)).foregroundColor(p.text.swiftUIColor)
                        .lineLimit(1).minimumScaleFactor(0.6).textSelection(.enabled)
                }
            } else {
                Text(model.status.snapshot?.online == false ? "Нет сети" : (model.status.lastCheck == nil ? "Проверка…" : "IP не подтверждён"))
                    .font(theme.font(18, weight: .semibold)).foregroundColor(p.muted.swiftUIColor)
            }
            Text(networkLine).font(theme.font(11)).foregroundColor(p.muted.swiftUIColor).lineLimit(2)
        }
    }

    private var apps: some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 6) {
            if model.shownApps.isEmpty {
                Text("Нет защищаемых приложений — добавьте их в панели")
                    .font(theme.font(11)).foregroundColor(p.muted.swiftUIColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.shownApps, id: \.self) { id in AppRow(model: model, id: id) }
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if case .paused(let until) = model.state {
                TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                    Button("Возобновить · \(Format.countdown(until.timeIntervalSince(ctx.date)))") { model.resumeProtection() }
                        .buttonStyle(SNButtonStyle(kind: .secondary, theme: theme))
                }
            } else {
                Menu {
                    Button("5 мин") { model.pause(for: 5 * 60) }
                    Button("15 мин") { model.pause(for: 15 * 60) }
                    Button("1 час") { model.pause(for: 60 * 60) }
                } label: {
                    Text("Пауза").font(theme.font(12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Metrics.smallCornerRadius).fill(theme.palette.surface.swiftUIColor))
                .overlay(RoundedRectangle(cornerRadius: Metrics.smallCornerRadius)
                    .stroke(theme.palette.hairline.swiftUIColor, lineWidth: Metrics.hairlineWidth))
            }
            Button("Панель →") { openPanel() }
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
        if s.dnsUnknown { w.append("DNS: нет данных о серверах, утечку проверить нельзя") }
        if model.config.dnsCheck == .warn, s.observation?.dnsLeak == true { w.append("Возможна утечка DNS мимо VPN") }
        if model.status.observation?.trustedNetwork == true { w.append("Доверенная сеть: VPN не требуется") }
        return w
    }

    private func openPanel() {
        openWindow(id: "panel")
        var opts: NSApplication.ActivationOptions = []
        if #unavailable(macOS 14) { opts.insert(.activateIgnoringOtherApps) }
        NSRunningApplication.current.activate(options: opts)
    }
}
