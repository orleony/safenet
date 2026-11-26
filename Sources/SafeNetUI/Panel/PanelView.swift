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
            Rectangle().fill(p.text.swiftUIColor.opacity(0.06)).frame(width: Metrics.hairlineWidth)
            ScrollView {
                content
                    .frame(maxWidth: 820, alignment: .topLeading)   // readable column, centred on wide/full-screen windows
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.horizontal, theme.padding + 14)
                    .padding(.vertical, theme.padding + 10)
            }
            .background(p.background.swiftUIColor)
        }
        .frame(minWidth: 680, minHeight: 460)
        .background(p.background.swiftUIColor)
        .onAppear { model.refreshAutostart() }
    }

    private var sidebar: some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: theme.smallGap + 2) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(stateColor(model.state, p).swiftUIColor)
                    .accessibilityHidden(true)
                Text("SafeNet").font(theme.display(16, weight: .bold)).foregroundColor(p.text.swiftUIColor)
            }
            .padding(.horizontal, theme.spacing - 4)
            .padding(.top, theme.smallGap)
            .padding(.bottom, theme.spacing + 4)
            ForEach(Array(PanelTab.allCases.enumerated()), id: \.element) { i, t in
                Button { tab = t } label: {
                    HStack(spacing: theme.spacing - 4) {
                        Image(systemName: t.symbol).frame(width: 16).accessibilityHidden(true)
                        Text(t.title).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(theme.font(12.5, weight: tab == t ? .semibold : .medium))
                    .foregroundColor((tab == t ? p.text : p.muted).swiftUIColor)
                    .padding(.horizontal, theme.spacing - 2).padding(.vertical, theme.rowPadding + 2)
                    .background(Capsule().fill(tab == t ? p.accent.swiftUIColor.opacity(0.16) : Color.clear))
                    .overlay(Capsule().strokeBorder(tab == t ? p.accent.swiftUIColor.opacity(0.18) : Color.clear,
                                                    lineWidth: Metrics.hairlineWidth))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                .accessibilityLabel(t.title)
                .accessibilityAddTraits(tab == t ? .isSelected : [])
            }
            Spacer()
            HStack(spacing: theme.smallGap + 1) {
                StatusDot(color: stateColor(model.state, p))
                Text(Format.stateTitle(model.state, hasApps: model.hasProtectedApps))
                    .font(theme.font(11, weight: .medium)).foregroundColor(p.muted.swiftUIColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, theme.spacing - 2)
            .padding(.bottom, theme.smallGap)
        }
        .padding(theme.spacing)
        .frame(width: 176)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            ZStack {
                GlassBackground(material: .sidebar)
                p.sidebar.swiftUIColor.opacity(theme.isDark ? 0.55 : 0.4)
            }
        )
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
