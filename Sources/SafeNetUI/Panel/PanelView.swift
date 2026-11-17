import SwiftUI
import SafeNetCore

public enum PanelTab: String, CaseIterable, Identifiable {
    case overview, apps, allowed, networks, check, journal, settings
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Обзор"
        case .apps: return "Приложения"
        case .allowed: return "Разрешено"
        case .networks: return "Сети"
        case .check: return "Проверка"
        case .journal: return "Журнал"
        case .settings: return "Настройки"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "shield.lefthalf.filled"
        case .apps: return "square.grid.2x2"
        case .allowed: return "checkmark.seal"
        case .networks: return "wifi"
        case .check: return "stethoscope"
        case .journal: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        }
    }
}

/// Panel window, style "A · Тёмное стекло": sidebar with the tabs (⌘1…⌘7) and the selected tab
/// on the background colour. A plain HStack instead of NavigationSplitView (stable on 13).
public struct PanelView: View {
    @ObservedObject var model: AppState
    @EnvironmentObject var theme: Theme
    @State private var tab: PanelTab

    public init(model: AppState, tab: PanelTab = .overview) {
        self.model = model
        _tab = State(initialValue: tab)
    }

    public var body: some View {
        let p = theme.palette
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(p.hairline.swiftUIColor).frame(width: Metrics.hairlineWidth)
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(theme.padding + 6)
            }
            .background(p.background.swiftUIColor)
        }
        .frame(minWidth: 680, minHeight: 460)
        .background(p.background.swiftUIColor)
    }

    private var sidebar: some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: theme.smallGap) {
                Image(systemName: Format.stateSymbol(model.state))
                    .foregroundColor(stateColor(model.state, p).swiftUIColor)
                    .accessibilityHidden(true)
                Text("SafeNet").font(theme.font(14, weight: .bold)).foregroundColor(p.text.swiftUIColor)
            }
            .padding(.horizontal, theme.spacing - 4)
            .padding(.bottom, theme.spacing)
            ForEach(Array(PanelTab.allCases.enumerated()), id: \.element) { i, t in
                Button { tab = t } label: {
                    HStack(spacing: theme.spacing - 4) {
                        Image(systemName: t.symbol).frame(width: 16).accessibilityHidden(true)
                        Text(t.title).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(theme.font(12, weight: tab == t ? .semibold : .regular))
                    .foregroundColor((tab == t ? p.text : p.muted).swiftUIColor)
                    .padding(.horizontal, theme.spacing - 4).padding(.vertical, theme.rowPadding + 1)
                    .background(RoundedRectangle(cornerRadius: Metrics.smallCornerRadius)
                        .fill(tab == t ? p.sidebarActive.swiftUIColor : Color.clear))
                    .overlay(alignment: .leading) {
                        if tab == t { Capsule().fill(p.accent.swiftUIColor).frame(width: 3, height: 14) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                .accessibilityLabel(t.title)
                .accessibilityAddTraits(tab == t ? .isSelected : [])
            }
            Spacer()
            Text(Format.stateTitle(model.state, hasApps: model.hasProtectedApps))
                .font(theme.font(10)).foregroundColor(p.muted.swiftUIColor)
                .padding(.horizontal, theme.spacing - 4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(theme.spacing)
        .frame(width: 160)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(p.sidebar.swiftUIColor)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .overview: OverviewTab(model: model, tab: $tab)
        case .apps: AppsTab(model: model)
        case .allowed: AllowedTab(model: model)
        case .networks: NetworksTab(model: model)
        case .check: CheckTab(model: model)
        case .journal: JournalTab(model: model)
        case .settings: SettingsTab(model: model)
        }
    }
}
