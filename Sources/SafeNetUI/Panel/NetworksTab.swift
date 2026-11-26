import SwiftUI
import SafeNetCore

/// "Сети": trusted networks (home/office without VPN), identified by gateway MAC + IP + subnet.
struct NetworksTab: View {
    @ObservedObject var model: AppState
    @EnvironmentObject var theme: Theme
    @State private var renaming: String?

    var body: some View {
        let p = theme.palette
        let trust = NetworkInput.trust(model.snapshot, existing: model.config.trustedNetworks)
        VStack(alignment: .leading, spacing: theme.spacing + 2) {
            SectionHeader(title: "Доверенные сети",
                          subtitle: "В доверенной сети (дом, офис) VPN не требуется: приложения работают без проверки IP. Все остальные сети под защитой. Сеть опознаётся по MAC-адресу шлюза вместе с его IP и подсетью — одинаковый 192.168.1.1 у чужого роутера доверия не даёт.")
            Card {
                CardTitle("Текущая сеть")
                if let s = model.snapshot {
                    Text(currentLine(s)).font(theme.font(12)).foregroundColor(p.muted.swiftUIColor)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if model.status.observation?.trustedNetwork == true {
                    Note("Эта сеть доверенная: VPN не требуется", symbol: "checkmark.seal", color: p.ok)
                }
                Button("Доверять этой сети") {
                    if let n = trust.network {
                        model.update { c in
                            if !c.trustedNetworks.contains(where: { $0.mac == n.mac && $0.ip == n.ip }) { c.trustedNetworks.append(n) }
                        }
                    }
                }
                .buttonStyle(SNButtonStyle(kind: .primary, theme: theme)).fixedSize()
                .disabled(trust.network == nil).opacity(trust.network == nil ? 0.5 : 1)
                if let why = trust.reason { Note(why, symbol: "info.circle") }
            }
            Card {
                CardTitle("Список")
                if model.config.trustedNetworks.isEmpty { Note("Доверенных сетей нет — защита действует везде.") }
                // Keyed by gateway MAC + IP (not the array index): a rename or a hot reload that
                // reorders the list keeps the row and its editor on the right network.
                ForEach(model.config.trustedNetworks, id: \.rowKey) { n in
                    if renaming == n.rowKey {
                        ValidatedField(label: "Название сети", placeholder: "Дом", actionTitle: "Сохранить", initial: n.name,
                                       validate: { t in
                                           let list = model.config.trustedNetworks
                                           guard let i = list.firstIndex(where: { $0.rowKey == n.rowKey }) else { return .fail("Сеть уже удалена") }
                                           if let e = NetworkInput.rename(t, index: i, in: list) { return .fail(e) }
                                           return .ok(t.trimmingCharacters(in: .whitespacesAndNewlines))
                                       },
                                       commit: { v in
                                           model.update { c in
                                               if let i = c.trustedNetworks.firstIndex(where: { $0.rowKey == n.rowKey }) { c.trustedNetworks[i].name = v }
                                           }
                                           renaming = nil
                                       })
                    } else {
                        HStack(spacing: theme.spacing - 4) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(n.name).font(theme.font(12, weight: .medium)).foregroundColor(p.text.swiftUIColor)
                                Text("шлюз \(n.ip) · \(n.mac) · \(n.subnet)").font(theme.font(10)).foregroundColor(p.muted.swiftUIColor)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button("Переименовать") { renaming = n.rowKey }
                                .buttonStyle(.plain).font(theme.font(11)).foregroundColor(p.accent.swiftUIColor)
                                .accessibilityLabel("Переименовать \(n.name)")
                            Button { model.update { c in c.trustedNetworks.removeAll { $0 == n } } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundColor(p.muted.swiftUIColor)
                                .accessibilityLabel("Удалить сеть \(n.name)").help("Удалить сеть")
                        }
                    }
                }
            }
        }
    }

    private func currentLine(_ s: NetSnapshot) -> String {
        guard s.online else { return "Нет сети" }
        var parts = [String]()
        if let i = s.interface { parts.append(i) }
        parts.append("шлюз " + (s.gatewayIP ?? "не виден"))
        parts.append("MAC " + (s.gatewayMAC ?? "неизвестен"))
        if let sub = s.subnet { parts.append(sub) }
        if s.hasTunnel { parts.append("VPN активен") }
        return parts.joined(separator: " · ")
    }
}

extension TrustedNetwork {
    /// Stable row identity for lists (gateway MAC + IP).
    var rowKey: String { mac.lowercased() + "|" + ip }
}
