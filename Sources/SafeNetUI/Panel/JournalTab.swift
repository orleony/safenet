import SwiftUI
import SafeNetCore

/// "Журнал": statistics counters and the event history (newest first) with filters and clearing.
struct JournalTab: View {
    @ObservedObject var model: AppState
    @EnvironmentObject var theme: Theme
    @State private var filter: Set<EventKind>?
    @State private var events: [Event] = []
    @State private var stats = Stats()
    @State private var confirmClear = false

    static let limit = 300

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.spacing + 2) {
            SectionHeader(title: "Статистика и журнал", subtitle: "Счётчики накапливаются с начала работы или с последней очистки.")
            HStack(spacing: theme.spacing - 2) {
                counter("\(stats.resumedInTime)", "VPN вернулся вовремя", "checkmark.circle", p.ok)
                counter("\(stats.freezes)", "Заморозок", "snowflake", p.frozen)
                counter("\(stats.closed)", "Закрытий", "xmark.circle", p.danger)
            }
            HStack(spacing: theme.smallGap) {
                Chip(title: "Все", selected: filter == nil) { filter = nil; reload() }
                ForEach(EventText.filters, id: \.title) { f in
                    Chip(title: f.title, selected: filter == f.kinds) { filter = f.kinds; reload() }
                }
                Spacer(minLength: theme.smallGap)
                Button("Очистить") { confirmClear = true }
                    .buttonStyle(SNButtonStyle(kind: .danger, theme: theme)).fixedSize()
                    .disabled(model.eventLog == nil)
                    .confirmationDialog("Очистить журнал и статистику?", isPresented: $confirmClear) {
                        Button("Очистить", role: .destructive) { model.eventLog?.clear(); reload() }
                        Button("Отмена", role: .cancel) {}
                    } message: { Text("Это действие нельзя отменить.") }
            }
            Card {
                if events.isEmpty { Note(filter == nil ? "Событий пока нет" : "Нет событий этого типа") }
                ForEach(Array(events.enumerated()), id: \.element.id) { i, e in
                    if i > 0 { Rectangle().fill(p.hairline.swiftUIColor).frame(height: Metrics.hairlineWidth) }
                    HStack(alignment: .firstTextBaseline, spacing: theme.spacing - 4) {
                        Image(systemName: EventText.symbol(e.kind)).foregroundColor(color(e.kind).swiftUIColor)
                            .frame(width: 16).accessibilityHidden(true)
                        Text(EventText.describe(e)).font(theme.font(12)).foregroundColor(p.text.swiftUIColor)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: theme.smallGap)
                        Text(e.date.formatted(date: .abbreviated, time: .standard))
                            .font(theme.font(10).monospacedDigit()).foregroundColor(p.muted.swiftUIColor).lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
                if events.count >= JournalTab.limit { Note("Показаны последние \(JournalTab.limit) событий") }
            }
        }
        .onAppear(perform: reload)
        // New events arrive with status changes: refresh then.
        .onReceive(model.$status) { _ in reload() }
    }

    private func reload() {
        guard let log = model.eventLog else { return }
        events = log.recent(limit: JournalTab.limit, kinds: filter)
        stats = log.stats()
    }

    private func color(_ k: EventKind) -> RGB {
        let p = theme.palette
        switch k {
        case .frozen: return p.frozen
        case .closed, .leak: return p.danger
        case .resumed: return p.ok
        default: return p.muted
        }
    }

    private func counter(_ value: String, _ title: String, _ symbol: String, _ c: RGB) -> some View {
        Card {
            HStack(spacing: theme.smallGap) {
                Image(systemName: symbol).foregroundColor(c.swiftUIColor).accessibilityHidden(true)
                Text(value).font(theme.font(22, weight: .semibold).monospacedDigit()).foregroundColor(theme.palette.text.swiftUIColor)
            }
            Text(title).font(theme.font(11)).foregroundColor(theme.palette.muted.swiftUIColor).lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }
}
