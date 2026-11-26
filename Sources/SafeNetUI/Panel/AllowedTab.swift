import SwiftUI
import SafeNetCore

/// "Разрешено": the common allow list (apps without own rules use it).
struct AllowedTab: View {
    @ObservedObject var model: AppState
    @EnvironmentObject var theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing + 2) {
            SectionHeader(title: "Разрешённые адреса и страны",
                          subtitle: "Приложения работают, только когда внешний IP совпадает с адресом или подсетью из списка ИЛИ находится в разрешённой стране. Общий список действует для приложений без своих правил.")
            if model.config.allow.ips.isEmpty && model.config.allow.countries.isEmpty {
                Note("Список пуст — значит, не разрешено ничего: все защищаемые приложения будут заморожены, пока вы не добавите страну или IP.",
                     symbol: "exclamationmark.triangle", color: theme.palette.frozen)
            }
            AllowListEditor(list: model.config.allow) { mutate in
                model.update { mutate(&$0.allow) }
            }
        }
    }
}

/// Countries and IPs of one allow list with add/remove and live validation.
struct AllowListEditor: View {
    let list: AllowList
    /// Applies a change to this list (through the engine's update path).
    let change: (@escaping (inout AllowList) -> Void) -> Void
    @EnvironmentObject var theme: Theme
    @State private var pick = ""

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.spacing + 2) {
            Card {
                CardTitle("Страны")
                if list.countries.isEmpty { Note("Нет разрешённых стран") }
                ForEach(list.countries, id: \.self) { cc in
                    RemovableRow(title: "\(Format.flag(cc)) \(Format.countryName(cc))", detail: cc.uppercased(),
                                 removeLabel: "Убрать страну \(Format.countryName(cc))") {
                        change { l in l.countries.removeAll { $0.uppercased() == cc.uppercased() } }
                    }
                }
                Rectangle().fill(p.hairline.swiftUIColor).frame(height: Metrics.hairlineWidth)
                HStack(spacing: theme.smallGap) {
                    Picker("Страна из списка", selection: $pick) {
                        Text("Выбрать страну…").tag("")
                        ForEach(AllowInput.countryChoices.filter { c in !list.countries.contains { $0.uppercased() == c.code } }, id: \.code) { c in
                            Text("\(c.flag) \(c.name)").tag(c.code)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                    .accessibilityLabel("Страна из списка")
                    Button("Добавить") {
                        let r = AllowInput.country(pick, existing: list.countries)
                        if let v = r.value { change { l in if !l.countries.contains(v) { l.countries.append(v) } } }
                        pick = ""
                    }
                    .buttonStyle(SNButtonStyle(kind: .primary, theme: theme)).fixedSize()
                    .disabled(pick.isEmpty)
                }
                ValidatedField(label: "Код страны", placeholder: "или код: NL, DE…", actionTitle: "Добавить код", width: 160,
                               validate: { AllowInput.country($0, existing: list.countries) },
                               commit: { v in change { l in if !l.countries.contains(v) { l.countries.append(v) } } })
            }
            Card {
                CardTitle("IP-адреса и подсети")
                if list.ips.isEmpty { Note("Нет разрешённых адресов") }
                ForEach(list.ips, id: \.self) { ip in
                    RemovableRow(title: ip, detail: ip.contains("/") ? "подсеть" : "адрес", removeLabel: "Убрать \(ip)") {
                        change { l in l.ips.removeAll { $0 == ip } }
                    }
                }
                Rectangle().fill(p.hairline.swiftUIColor).frame(height: Metrics.hairlineWidth)
                ValidatedField(label: "IP-адрес или подсеть", placeholder: "203.0.113.7 или 10.0.0.0/8", actionTitle: "Добавить",
                               validate: { AllowInput.ip($0, existing: list.ips) },
                               commit: { v in change { l in if !l.ips.contains(v) { l.ips.append(v) } } })
            }
        }
    }
}
