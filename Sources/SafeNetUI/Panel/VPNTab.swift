import SwiftUI
import SafeNetCore

/// "VPN": the built-in client. The user pastes a subscription URL or server links; SafeNet runs
/// the tunnel (sing-box through the root helper) and keeps the kill switch.
struct VPNTab: View {
    @ObservedObject var model: AppState
    @ObservedObject var vpn: VPNController
    @EnvironmentObject var theme: Theme
    @State private var input = ""

    init(model: AppState) {
        self.model = model
        vpn = model.vpn
    }

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.spacing + 2) {
            SectionHeader(title: "VPN",
                          subtitle: "Свой VPN: вставьте ссылку подписки от провайдера или ссылку на сервер (vless, vmess, trojan, ss, hysteria2, tuic). Пока VPN включён и туннель не поднят, защищаемые приложения заморожены.")
            Card {
                HStack(spacing: theme.spacing - 2) {
                    StatusDot(color: statusColor(p))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle).font(theme.display(16)).foregroundColor(p.text.swiftUIColor)
                        if let s = statusDetail {
                            Text(s).font(theme.font(11)).foregroundColor(p.muted.swiftUIColor)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                    Spacer()
                    if vpn.settings.enabled {
                        Button("Отключить") { vpn.disconnect() }
                            .buttonStyle(SNButtonStyle(kind: .secondary, theme: theme)).fixedSize()
                            .disabled(vpn.busy != nil)
                    } else {
                        Button("Подключить") { vpn.connect() }
                            .buttonStyle(SNButtonStyle(kind: .primary, theme: theme)).fixedSize()
                            .disabled(!vpn.canConnect).opacity(vpn.canConnect ? 1 : 0.5)
                    }
                }
                if vpn.settings.enabled, vpn.isRunning, let ip = model.lastIP, !ip.country.isEmpty, !isAllowed(ip) {
                    HStack {
                        Note("Сервер выходит в \(Format.flag(ip.country)) \(Format.countryName(ip.country)) — эта страна не разрешена, приложения заморожены.",
                             symbol: "exclamationmark.triangle", color: p.frozen)
                        Spacer()
                        Button("Разрешить") { model.allowCurrentCountry() }
                            .buttonStyle(SNButtonStyle(kind: .primary, theme: theme)).fixedSize()
                    }
                }
                if let b = vpn.busy { Note(b, symbol: "hourglass") }
                if let m = vpn.message { Note(m, symbol: "info.circle") }
                if vpn.coreMissing {
                    Note("VPN подключается только из SafeNet.app (не из разработческой сборки).", symbol: "exclamationmark.triangle", color: p.frozen)
                }
            }
            Card {
                CardTitle("Что идёт через VPN")
                Segmented(options: [(VPNMode.all, "Весь трафик"), (VPNMode.apps, "Только защищаемые приложения")],
                          selection: vpn.settings.mode) { vpn.setMode($0) }
                Note(vpn.settings.mode == .all
                     ? "Весь трафик Mac идёт через сервер, кроме локальной сети. Если сервер недоступен, интернет не работает — ничего не утечёт."
                     : "Через сервер идут только приложения из вкладки «Приложения», остальное — напрямую. Правила работают по пути к программе (…/Claude.app/) и имени процесса.")
            }
            Card {
                CardTitle("Добавить")
                HStack(spacing: theme.spacing - 4) {
                    TextField("https://… подписка или vless://… сервер", text: $input)
                        .textFieldStyle(.plain).font(theme.font(12)).foregroundColor(p.text.swiftUIColor)
                        .padding(.horizontal, theme.spacing - 4).padding(.vertical, theme.rowPadding)
                        .background(RoundedRectangle(cornerRadius: Metrics.smallCornerRadius).fill(p.surface.swiftUIColor))
                        .overlay(RoundedRectangle(cornerRadius: Metrics.smallCornerRadius).stroke(p.hairline.swiftUIColor, lineWidth: Metrics.hairlineWidth))
                        .accessibilityLabel("Ссылка подписки или сервера")
                        .onSubmit(add)
                    Button("Из буфера") {
                        if let s = NSPasteboard.general.string(forType: .string) { input = s; add() }
                    }
                    .buttonStyle(SNButtonStyle(kind: .secondary, theme: theme)).fixedSize()
                    Button("Добавить", action: add)
                        .buttonStyle(SNButtonStyle(kind: .primary, theme: theme)).fixedSize()
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || vpn.busy != nil)
                }
            }
            Card {
                CardTitle("Серверы")
                if vpn.settings.sources.isEmpty { Note("Серверов пока нет. Добавьте подписку или ссылку выше.") }
                ForEach(vpn.settings.sources) { src in
                    sourceView(src)
                }
            }
            Card {
                CardTitle("Системный помощник")
                Note(helperText, symbol: "lock.shield")
                if case .notInstalled = vpn.helper {} else if case .unknown = vpn.helper {} else {
                    Button("Удалить помощник") { vpn.removeHelper() }
                        .buttonStyle(SNButtonStyle(kind: .danger, theme: theme)).fixedSize()
                        .disabled(vpn.busy != nil)
                }
                Note("VPN работает на ядре sing-box \(SingBoxRelease.version) (GPL-3.0, github.com/SagerNet/sing-box) — отдельной программой рядом с SafeNet. Ядро скачивается с GitHub при первом подключении и сверяется по SHA-256.")
            }
        }
    }

    private func add() {
        let t = input
        input = ""
        vpn.add(t)
    }

    private func isAllowed(_ ip: IPAnswer) -> Bool {
        Engine.leakAllow(model.config).countries.contains { $0.uppercased() == ip.country.uppercased() }
            || Engine.leakAllow(model.config).ips.contains { IPMatcher.matches(ip.ip, entry: $0) }
    }

    @ViewBuilder private func sourceView(_ src: VPNSource) -> some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 4) {
            if src.kind == .subscription { sourceHeader(src) }
            ForEach(src.profiles, id: \.id) { prof in profileRow(prof, src: src) }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func sourceHeader(_ src: VPNSource) -> some View {
        let p = theme.palette
            HStack(spacing: theme.spacing - 4) {
                Image(systemName: src.kind == .subscription ? "arrow.triangle.2.circlepath" : "link")
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(p.muted.swiftUIColor)
                Text(src.displayTitle).font(theme.font(12, weight: .semibold)).foregroundColor(p.text.swiftUIColor).lineLimit(1)
                if let info = src.info { Text(infoLine(info)).font(theme.font(10)).foregroundColor(p.muted.swiftUIColor).lineLimit(1) }
                Spacer()
                if src.kind == .subscription {
                    Button("Обновить") { vpn.refresh(src.id) }
                        .buttonStyle(.plain).font(theme.font(11)).foregroundColor(p.accent.swiftUIColor)
                        .disabled(vpn.busy != nil)
                }
                Button { vpn.remove(src.id) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain).foregroundColor(p.muted.swiftUIColor)
                    .help("Удалить").accessibilityLabel("Удалить \(src.displayTitle)")
            }
    }

    @ViewBuilder private func profileRow(_ prof: VPNProfile, src: VPNSource) -> some View {
        let p = theme.palette
        let on = prof.id == vpn.settings.selected
        HStack(spacing: theme.spacing - 4) {
                Button { vpn.select(prof.id) } label: {
                    HStack(spacing: theme.spacing - 4) {
                        Image(systemName: on ? "largecircle.fill.circle" : "circle")
                            .foregroundColor((on ? p.accent : p.muted).swiftUIColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(prof.name).font(theme.font(12, weight: on ? .semibold : .regular)).foregroundColor(p.text.swiftUIColor).lineLimit(1)
                            Text(prof.summary).font(theme.font(10)).foregroundColor(p.muted.swiftUIColor).lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                if src.kind == .link {
                    Button { vpn.remove(src.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundColor(p.muted.swiftUIColor)
                        .help("Удалить").accessibilityLabel("Удалить \(prof.name)")
                }
        }
        .padding(.leading, src.kind == .subscription ? 18 : 0)
    }

    private func infoLine(_ i: SubscriptionInfo) -> String {
        var parts: [String] = []
        if let t = i.total {
            let used = (i.upload ?? 0) + (i.download ?? 0)
            parts.append("\(gb(used)) из \(gb(t)) ГБ")
        }
        if let e = i.expire {
            let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMM yyyy"
            parts.append("до \(f.string(from: e))")
        }
        return parts.joined(separator: " · ")
    }
    private func gb(_ b: Int64) -> String { String(format: "%.1f", Double(b) / 1_073_741_824) }

    private var statusTitle: String {
        if !vpn.settings.enabled { return "Выключен" }
        switch vpn.helperStatus?.state {
        case .running?: return "Подключён"
        case .starting?: return "Подключается…"
        case .failed?: return "Ошибка"
        default: return vpn.busy != nil ? "Подключается…" : "Не подключён"
        }
    }

    private var statusDetail: String? {
        let server = vpn.settings.selectedProfile.map { "\($0.name) · \($0.summary)" }
        if vpn.settings.enabled, vpn.helperStatus?.state == .failed { return vpn.helperStatus?.message ?? server }
        if vpn.settings.enabled, !vpn.isRunning { return (server.map { $0 + ". " } ?? "") + "Защищаемые приложения заморожены, пока туннель не поднят." }
        return server ?? "Сервер не выбран"
    }

    private func statusColor(_ p: Palette) -> RGB {
        if !vpn.settings.enabled { return p.muted }
        if vpn.isRunning { return p.ok }
        return vpn.helperStatus?.state == .failed ? p.danger : p.frozen
    }

    private var helperText: String {
        switch vpn.helper {
        case .unknown: return "Проверяю помощник…"
        case .notInstalled: return "Не установлен. При первом подключении macOS попросит пароль администратора: помощник создаёт туннель и не выпускает трафик мимо VPN."
        case .outdated: return "Установлен от другой версии SafeNet — обновится при подключении (macOS попросит пароль)."
        case .ready(let s): return "Установлен (sing-box \(s.singBoxVersion.isEmpty ? "?" : s.singBoxVersion))."
        }
    }
}
