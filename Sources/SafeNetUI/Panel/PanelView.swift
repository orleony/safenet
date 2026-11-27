import SwiftUI
import SafeNetCore

public enum PanelTab: String, CaseIterable, Identifiable {
    case overview, vpn, apps, allowed, networks, check, journal, settings
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Обзор"
        case .vpn: return "VPN"
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
        case .vpn: return "lock.shield"
        case .apps: return "square.grid.2x2"
        case .allowed: return "checkmark.seal"
        case .networks: return "wifi"
        case .check: return "stethoscope"
        case .journal: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        }
    }
}

enum InspectorLayout {
    static func contentWidth(for windowWidth: CGFloat) -> CGFloat {
        max(0, min(960, windowWidth - 62))
    }

    static func settingsUseColumns(for windowWidth: CGFloat) -> Bool {
        contentWidth(for: windowWidth) >= 768
    }
}

/// Inspector window with a fixed header and a shared measure for its tabs and scroll area.
public struct PanelView: View {
    @ObservedObject var model: AppState
    @EnvironmentObject var theme: Theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var tab: PanelTab

    public init(model: AppState, tab: PanelTab = .overview) {
        self.model = model
        _tab = State(initialValue: tab)
    }

    public var body: some View {
        bodyContent
            .onReceive(model.$requestedTab) { t in
                guard let t = t else { return }
                tab = t
                DispatchQueue.main.async { model.requestedTab = nil }
            }
    }

    private var bodyContent: some View {
        GeometryReader { geometry in
            let width = InspectorLayout.contentWidth(for: geometry.size.width)
            VStack(spacing: 0) {
                header(width: width)
                ScrollView {
                    content(settingsUseColumns: InspectorLayout.settingsUseColumns(for: geometry.size.width))
                        .frame(width: width, alignment: .topLeading)
                        .padding(.vertical, theme.padding + 10)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                .background(theme.palette.background.swiftUIColor)
            }
        }
        .frame(minWidth: 680, minHeight: 460)
        .onAppear { model.refreshAutostart() }
    }

    private func header(width: CGFloat) -> some View {
        let p = theme.palette
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                ZStack(alignment: .trailing) {
                    HStack(spacing: theme.smallGap) {
                        AppMark(size: 20)
                        Text("SafeNet").font(theme.font(14, weight: .semibold))
                        if AppState.isDevBuild {
                            Text("DEV").font(theme.font(9, weight: .bold)).foregroundColor(p.frozen.swiftUIColor)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(p.frozen.swiftUIColor.opacity(0.18)))
                                .help("Разработческая сборка: обновления выключены")
                        }
                    }
                    .foregroundColor(p.text.swiftUIColor)
                    .frame(maxWidth: .infinity)

                    HStack(spacing: theme.smallGap) {
                        let color = model.state == .ok && !model.hasProtectedApps ? p.muted : stateColor(model.state, p)
                        Circle().fill(color.swiftUIColor).frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(Format.stateTitle(model.state, hasApps: model.hasProtectedApps))
                            .font(theme.font(11)).foregroundColor(p.text.swiftUIColor).lineLimit(1)
                    }
                }
                .frame(height: 40)
                ViewThatFits(in: .horizontal) {
                    navigation(showSymbols: true)
                    navigation(showSymbols: false)
                }
            }
            .frame(width: width)
            .frame(maxWidth: .infinity)
            Rectangle().fill(p.hairline.swiftUIColor.opacity(0.7))
                .frame(height: Metrics.hairlineWidth)
        }
        .background {
            if reduceTransparency {
                p.surface.swiftUIColor
            } else {
                GlassBackground(material: .headerView).overlay(p.background.swiftUIColor.opacity(0.46))
            }
        }
    }

    private func navigation(showSymbols: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(PanelTab.allCases.enumerated()), id: \.element) { i, t in
                InspectorTabButton(title: t.title, symbol: showSymbols ? t.symbol : nil, selected: tab == t) {
                    tab = t
                }
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                if t != PanelTab.allCases.last {
                    Spacer(minLength: theme.spacing)
                }
            }
        }
    }

    @ViewBuilder private func content(settingsUseColumns: Bool) -> some View {
        switch tab {
        case .overview: OverviewTab(model: model, tab: $tab)
        case .vpn: VPNTab(model: model)
        case .apps: AppsTab(model: model)
        case .allowed: AllowedTab(model: model)
        case .networks: NetworksTab(model: model)
        case .check: CheckTab(model: model)
        case .journal: JournalTab(model: model)
        case .settings: SettingsTab(model: model, useColumns: settingsUseColumns)
        }
    }
}

struct InspectorTabButton: View {
    @EnvironmentObject private var theme: Theme
    @State private var hovering = false
    let title: String
    var symbol: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let p = theme.palette
        Button(action: action) {
            HStack(spacing: theme.smallGap) {
                if let symbol {
                    Image(systemName: symbol).accessibilityHidden(true)
                }
                Text(title).lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .font(theme.font(12, weight: selected ? .semibold : .medium))
            .foregroundColor((selected || hovering ? p.text : p.muted).swiftUIColor)
            .padding(.vertical, theme.rowPadding + 3)
            .overlay(alignment: .bottom) {
                if selected { Capsule().fill(p.accent.swiftUIColor).frame(height: 2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
