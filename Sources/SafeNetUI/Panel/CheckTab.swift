import SwiftUI
import SafeNetCore

/// "Проверка": deep leak check on demand, every result as its own row with advice.
struct CheckTab: View {
    @ObservedObject var model: AppState
    @EnvironmentObject var theme: Theme
    /// Renders/previews: a finished check shown instead of the model's.
    private let preset: DeepCheckData?

    init(model: AppState, preset: DeepCheckData? = nil) {
        self.model = model
        self.preset = preset
    }

    private var running: Bool { model.deepCheckRunning }
    private var result: DeepCheckData? { model.lastDeepCheck ?? preset }

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.spacing + 2) {
            SectionHeader(title: "Проверка на утечки",
                          subtitle: "Опрашивает каждый IP-сервис отдельно, проверяет IPv6, DNS-серверы и маршрут до пяти ИИ-сервисов. Запросы уходят только IP-сервисам и на /cdn-cgi/trace этих ИИ-сервисов — по кнопке, даже если защищаемых приложений нет.")
            if let w = model.proxyWarning { Note(w, symbol: "exclamationmark.triangle", color: p.danger) }
            HStack(spacing: theme.spacing - 4) {
                Button(running ? "Проверяю…" : "Проверить на утечки") { model.runDeepCheck() }
                .buttonStyle(SNButtonStyle(kind: .primary, theme: theme)).fixedSize()
                .disabled(running || !model.canDeepCheck)
                if running { ProgressView().controlSize(.small).accessibilityLabel("Идёт проверка") }
                if let r = result {
                    Text("Проверено в \(r.finished.formatted(date: .omitted, time: .standard))")
                        .font(theme.font(11)).foregroundColor(p.muted.swiftUIColor)
                }
            }
            if let r = result {
                ForEach(DeepCheck.sections(r, config: model.config)) { s in
                    Card {
                        Text(s.title).font(theme.display(13)).foregroundColor(p.text.swiftUIColor)
                        ForEach(s.rows) { row in rowView(row) }
                    }
                }
                Note("«Не проверено» значит, что ответа не было: такой результат никогда не считается хорошим.", symbol: "info.circle")
            } else if !running {
                Note("Проверка ещё не запускалась.")
            }
        }
    }

    private func rowView(_ r: CheckRow) -> some View {
        let p = theme.palette
        return HStack(alignment: .firstTextBaseline, spacing: theme.spacing - 4) {
            LevelIcon(level: r.level)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: theme.smallGap) {
                    Text(r.title).font(theme.font(12, weight: .medium)).foregroundColor(p.text.swiftUIColor)
                    Text(r.detail).font(theme.font(12)).foregroundColor(p.muted.swiftUIColor)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if let a = r.advice {
                    Text("Что сделать: " + a).font(theme.font(11)).foregroundColor(p.text.swiftUIColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
