import SwiftUI
import SafeNetCore

/// "Обзор": the menu window's state, larger, plus every check's state line.
struct OverviewTab: View {
    @ObservedObject var model: AppState
    @Binding var tab: PanelTab
    @EnvironmentObject var theme: Theme

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.spacing + 2) {
            Card {
                HStack(spacing: theme.spacing - 4) {
                    Image(systemName: Format.stateSymbol(model.state))
                        .foregroundColor(stateColor(model.state, p).swiftUIColor).font(.system(size: 16))
                        .accessibilityHidden(true)
                    Text(Format.stateTitle(model.state, hasApps: model.hasProtectedApps))
                        .font(theme.font(16, weight: .semibold)).foregroundColor(p.text.swiftUIColor)
                    Spacer()
                    if model.testMode != nil { Badge(text: "ТЕСТОВЫЙ РЕЖИМ", color: p.frozen) }
                }
                ipLine
                if !expected.isEmpty {
                    Text("Ожидается: " + expected).font(theme.font(11)).foregroundColor(p.muted.swiftUIColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(model.messages, id: \.text) { m in
                HStack(alignment: .top) {
                    Note(m.text, symbol: m.isError ? "xmark.octagon" : "info.circle", color: m.isError ? p.danger : p.muted)
                    Spacer()
                    if !m.isError, m.text == model.notice {
                        Button("Скрыть") { model.dismissNotice() }.buttonStyle(.plain)
                            .font(theme.font(11)).foregroundColor(p.accent.swiftUIColor)
                    }
                }
            }
            if let w = model.proxyWarning {
                Card { Note(w, symbol: "exclamationmark.triangle", color: p.danger) }
            }
            if model.needsAllowSetup { firstRun }
            if case .frozen(let since, let r, let d) = model.state { PanelFrozenCard(model: model, since: since, reason: r, deadline: d) }
            if case .closed(let at) = model.state {
                Card {
                    Note("Закрыты в \(at.formatted(date: .omitted, time: .shortened)). Вернутся под защиту после успешной проверки; запущенные снова будут заморожены.",
                         symbol: "xmark.circle", color: p.danger)
                }
            }
            Card {
                Text("Проверки").font(theme.font(12, weight: .semibold)).foregroundColor(p.text.swiftUIColor)
                ForEach(lines, id: \.0) { l in
                    HStack(alignment: .firstTextBaseline, spacing: theme.spacing - 4) {
                        LevelIcon(level: l.2)
                        Text(l.0).font(theme.font(12, weight: .medium)).foregroundColor(p.text.swiftUIColor).frame(width: 150, alignment: .leading)
                        Text(l.1).font(theme.font(12)).foregroundColor(p.muted.swiftUIColor).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            pauseRow
        }
    }

    private var ipLine: some View {
        let p = theme.palette
        return Group {
            if let a = model.lastIP {
                HStack(spacing: theme.spacing - 2) {
                    Text(Format.flag(a.country)).font(.system(size: 32))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.ip).font(theme.font(24, weight: .semibold)).foregroundColor(p.text.swiftUIColor)
                            .lineLimit(1).minimumScaleFactor(0.6).textSelection(.enabled)
                        Text(Format.countryName(a.country)).font(theme.font(12)).foregroundColor(p.muted.swiftUIColor)
                    }
                }
            } else if let country = model.status.sharedCountry {
                Text("\(Format.flag(country)) \(Format.countryName(country)) · несколько IP")
                    .font(theme.font(18, weight: .semibold)).foregroundColor(p.text.swiftUIColor)
            } else {
                Text(model.snapshot?.online == false ? "Нет сети" : (model.status.lastCheck == nil ? "Проверка…" : "IP не подтверждён"))
                    .font(theme.font(20, weight: .semibold)).foregroundColor(p.muted.swiftUIColor)
            }
        }
    }

    private var firstRun: some View {
        Card {
            Text("Выберите разрешённые страны или IP").font(theme.font(13, weight: .semibold)).foregroundColor(theme.palette.text.swiftUIColor)
            Note("Пока список пуст, выбранные приложения заморожены (но не закрываются), пока вы не укажете разрешённую страну или IP. Сами мы ничего не разрешаем.")
            HStack(spacing: theme.spacing - 4) {
                if let a = model.lastIP {
                    Button("Разрешить \(Format.flag(a.country)) \(Format.countryName(a.country))") { model.allowCurrentCountry() }
                        .buttonStyle(SNButtonStyle(kind: .primary, theme: theme)).fixedSize()
                }
                Button("Открыть «Разрешено»") { tab = .allowed }
                    .buttonStyle(SNButtonStyle(kind: .secondary, theme: theme)).fixedSize()
            }
        }
    }

    private var pauseRow: some View {
        HStack(spacing: theme.spacing - 4) {
            if case .paused(let until?) = model.state {
                TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                    Button("Возобновить защиту · \(Format.countdown(until.timeIntervalSince(ctx.date)))") { model.resumeProtection() }
                        .buttonStyle(SNButtonStyle(kind: .primary, theme: theme)).fixedSize()
                }
            } else if case .paused = model.state {
                Button("Возобновить защиту") { model.resumeProtection() }
                    .buttonStyle(SNButtonStyle(kind: .primary, theme: theme)).fixedSize()
                Note("Пауза до перезапуска")
            } else {
                Button("Пауза на \(Int(model.defaultPause / 60)) мин") { model.pause() }
                    .buttonStyle(SNButtonStyle(kind: .secondary, theme: theme)).fixedSize()
                    .disabled(!model.hasProtectedApps)
                Button("Проверить сейчас") { model.checkNow() }
                    .buttonStyle(SNButtonStyle(kind: .secondary, theme: theme)).fixedSize()
            }
            Spacer()
        }
    }

    /// Allowed countries/IPs, flags and names (common list; per-app rules noted).
    private var expected: String {
        let a = model.config.allow
        var parts = a.countries.map { "\(Format.flag($0)) \(Format.countryName($0))" } + a.ips
        let own = AppCatalog.appIDs(in: model.config).filter { model.config.appRules[$0] != nil }.count
        if own > 0 { parts.append("у \(own) прилож. свои правила") }
        return parts.joined(separator: ", ")
    }

    /// (title, text, level) per check.
    private var lines: [(String, String, CheckLevel)] {
        let s = model.status, c = model.config, o = s.observation
        var out: [(String, String, CheckLevel)] = []
        if let snap = s.snapshot {
            out.append(("VPN", snap.hasTunnel ? "туннель активен" : "туннель не найден", snap.hasTunnel ? .ok : .warn))
            var net = [String]()
            if let i = snap.interface { net.append(i) }
            if let g = snap.gatewayIP { net.append("шлюз \(g)") }
            if let m = snap.gatewayMAC { net.append(m) }
            out.append(("Сеть", net.isEmpty ? (snap.online ? "шлюз не виден" : "нет сети") : net.joined(separator: " · "),
                        snap.online ? .ok : .fail))
        } else {
            out.append(("Сеть", "ещё не определена", .unknown))
        }
        if o?.trustedNetwork == true { out.append(("Доверенная сеть", "VPN здесь не требуется", .ok)) }
        if c.checkIPv6 {
            out.append(("IPv6", o == nil ? "ещё не проверено" : (o!.ipv6Leak ? "утечка мимо VPN" : "чисто"),
                        o == nil ? .unknown : (o!.ipv6Leak ? .fail : .ok)))
        } else { out.append(("IPv6", "проверка выключена", .unknown)) }
        switch c.dnsCheck {
        case .off: out.append(("DNS", "проверка выключена", .unknown))
        default:
            if s.dnsUnknown { out.append(("DNS", "нет данных о DNS-серверах, утечку проверить нельзя", .warn)) }
            else if o?.dnsLeak == true { out.append(("DNS", "возможна утечка мимо VPN", c.dnsCheck == .block ? .fail : .warn)) }
            else if o == nil { out.append(("DNS", "ещё не проверено", .unknown)) }
            else { out.append(("DNS", "без утечек", .ok)) }
        }
        if !c.routeCheck { out.append(("Маршрут ИИ", "проверка выключена", .unknown)) }
        else if !s.routesChecked { out.append(("Маршрут ИИ", model.hasProtectedApps ? "ещё не проверен" : "нет защищаемых приложений", .unknown)) }
        else { out.append(("Маршрут ИИ", o?.routeLeak == true ? "идёт мимо разрешённых адресов" : "через разрешённые адреса", o?.routeLeak == true ? .fail : .ok)) }
        if let t = s.lastCheck { out.append(("Последняя проверка", t.formatted(date: .omitted, time: .standard), .ok)) }
        return out
    }
}

/// Frozen state in the panel: reason, countdown with progress bar, actions.
struct PanelFrozenCard: View {
    @ObservedObject var model: AppState
    @EnvironmentObject var theme: Theme
    let since: Date
    let reason: Reason
    let deadline: Date?
    @State private var confirmClose = false

    var body: some View {
        let p = theme.palette
        let col = stateColor(model.state, p)
        Card {
            Label(Format.reason(reason).prefix(1).uppercased() + String(Format.reason(reason).dropFirst()),
                  systemImage: reason == .freezeFailed ? "xmark.octagon" : "snowflake")
                .font(theme.font(13, weight: .semibold)).foregroundColor(col.swiftUIColor)
            if let d = deadline {
                TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                    let left = d.timeIntervalSince(ctx.date), total = max(1, d.timeIntervalSince(since))
                    VStack(alignment: .leading, spacing: theme.smallGap) {
                        Text("\(model.config.onTimeout == .close ? "Закрытие через" : "Срок заморозки") \(Format.countdown(left))")
                            .font(theme.font(22, weight: .semibold).monospacedDigit()).foregroundColor(p.text.swiftUIColor)
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(p.hairline.swiftUIColor)
                                Capsule().fill(col.swiftUIColor).frame(width: g.size.width * CGFloat(min(1, max(0, left / total))))
                            }
                        }
                        .frame(height: 6)
                        .accessibilityLabel("Осталось \(Format.countdown(left))")
                    }
                }
            } else {
                Note(reason == .offline ? "Без сети приложения не закрываются." : "Ждёт следующей проверки.")
            }
            HStack(spacing: theme.spacing - 4) {
                Button("Разрешить этот IP") { model.allowCurrent() }
                    .buttonStyle(SNButtonStyle(kind: .secondary, theme: theme)).disabled(model.lastIP == nil)
                Button("Продлить на 1 мин") { model.extend(by: 60) }
                    .buttonStyle(SNButtonStyle(kind: .secondary, theme: theme)).disabled(deadline == nil)
                Button("Закрыть сейчас") { confirmClose = true }
                    .buttonStyle(SNButtonStyle(kind: .danger, theme: theme))
            }
            .confirmationDialog("Закрыть замороженные приложения сейчас?", isPresented: $confirmClose) {
                Button("Закрыть", role: .destructive) { model.closeNow() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Несохранённые данные в них могут пропасть.")
            }
        }
    }
}
