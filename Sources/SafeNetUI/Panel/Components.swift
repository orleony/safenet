import SwiftUI
import AppKit
import SafeNetCore

/// Opens the panel from the accessory (no Dock icon) app: activate first so the new window
/// becomes key, then open it, then bring an already open panel to the front.
enum PanelOpener {
    /// Remembered from the menu window's CONTENT view, so the CLI can open the panel without a
    /// view at hand. Main thread only. (An `openWindow` taken from the MenuBarExtra LABEL is inert
    /// on macOS 13: calling it creates no window. The content's one works, but the content exists
    /// only after the menu was opened once; until then the Window menu item is used.)
    private static var action: OpenWindowAction?
    static func register(_ openWindow: OpenWindowAction) { action = openWindow }

    static func panelWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("panel") == true }
    }

    /// The item SwiftUI adds to the app's Window menu for the `Window("SafeNet", id: "panel")`
    /// scene (title = scene title). The app menu (first item) is skipped.
    static func windowMenuItem() -> NSMenuItem? {
        guard let items = NSApp.mainMenu?.items.dropFirst() else { return nil }
        for sub in items.compactMap({ $0.submenu }) {
            if let i = sub.items.first(where: { $0.title == "SafeNet" && $0.action != nil }) { return i }
        }
        return nil
    }

    /// `SafeNetApp panel`: main thread. Brings an existing panel forward, else opens it through the
    /// remembered content action, else through the Window menu item. Reports (asynchronously,
    /// main thread) whether a visible panel window exists afterwards.
    static func openFromCLI(done: @escaping (Bool) -> Void) {
        var opts: NSApplication.ActivationOptions = []
        if #unavailable(macOS 14) { opts.insert(.activateIgnoringOtherApps) }
        NSRunningApplication.current.activate(options: opts)
        if panelWindows().isEmpty {
            if let a = action {
                a(id: "panel")
            } else if let item = windowMenuItem(), let sel = item.action {
                NSApp.sendAction(sel, to: item.target, from: item)
            }
        }
        var tries = 0
        func check() {
            let panels = panelWindows()
            panels.forEach { $0.makeKeyAndOrderFront(nil) }
            if panels.contains(where: { $0.isVisible }) { done(true); return }
            tries += 1
            if tries >= 10 { done(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: check)
        }
        DispatchQueue.main.async(execute: check)
    }

    static func open(_ openWindow: OpenWindowAction) {
        var opts: NSApplication.ActivationOptions = []
        if #unavailable(macOS 14) { opts.insert(.activateIgnoringOtherApps) }
        NSRunningApplication.current.activate(options: opts)
        openWindow(id: "panel")
        DispatchQueue.main.async {
            for w in panelWindows() { w.makeKeyAndOrderFront(nil) }
        }
    }
}

/// Rounded surface card with a hairline border.
struct Card<Content: View>: View {
    @EnvironmentObject var theme: Theme
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing - 2) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(theme.padding)
            .background(RoundedRectangle(cornerRadius: Metrics.cornerRadius).fill(theme.palette.surface.swiftUIColor))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cornerRadius)
                .stroke(theme.palette.hairline.swiftUIColor, lineWidth: Metrics.hairlineWidth))
    }
}

/// Tab title with an optional explanation line.
struct SectionHeader: View {
    @EnvironmentObject var theme: Theme
    let title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(theme.font(14, weight: .semibold)).foregroundColor(theme.palette.text.swiftUIColor)
                .accessibilityAddTraits(.isHeader)
            if let s = subtitle {
                Text(s).font(theme.font(11)).foregroundColor(theme.palette.muted.swiftUIColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Muted explanatory paragraph.
struct Note: View {
    @EnvironmentObject var theme: Theme
    let text: String
    var symbol: String?
    var color: RGB?
    init(_ text: String, symbol: String? = nil, color: RGB? = nil) { self.text = text; self.symbol = symbol; self.color = color }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.smallGap) {
            if let s = symbol { Image(systemName: s).accessibilityHidden(true) }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(theme.font(11))
        .foregroundColor((color ?? theme.palette.muted).swiftUIColor)
    }
}

/// Selectable chip (filters, accent swatches). Selection is shown by fill AND a checkmark.
struct Chip: View {
    @EnvironmentObject var theme: Theme
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        let p = theme.palette
        Button(action: action) {
            HStack(spacing: 3) {
                if selected { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                Text(title).lineLimit(1)
            }
            .fixedSize()
            .font(theme.font(11, weight: .medium))
            .foregroundColor((selected ? p.onAccent : p.text).swiftUIColor)
            .padding(.horizontal, theme.spacing - 2).padding(.vertical, theme.smallGap)
            .background(Capsule().fill((selected ? p.accent : p.surface).swiftUIColor))
            .overlay(Capsule().stroke(p.hairline.swiftUIColor, lineWidth: selected ? 0 : Metrics.hairlineWidth))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Segmented choice drawn with the theme (same look offscreen and on screen); each option is a
/// focusable button with its own label.
struct Segmented<T: Hashable>: View {
    @EnvironmentObject var theme: Theme
    let options: [(T, String)]
    let selection: T
    let onSelect: (T) -> Void
    var body: some View {
        let p = theme.palette
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { opt in
                let on = opt.0 == selection
                Button { onSelect(opt.0) } label: {
                    Text(opt.1)
                        .font(theme.font(11, weight: on ? .semibold : .regular))
                        .foregroundColor((on ? p.onAccent : p.text).swiftUIColor)
                        .lineLimit(1)
                        .padding(.horizontal, theme.spacing - 2).padding(.vertical, theme.smallGap)
                        .background(RoundedRectangle(cornerRadius: 6).fill(on ? p.accent.swiftUIColor : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(p.background.swiftUIColor))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.hairline.swiftUIColor, lineWidth: Metrics.hairlineWidth))
        .fixedSize()
    }
}

/// Switch drawn with the theme; the state is also spoken ("вкл"/"выкл") and the label is kept.
struct SNSwitchStyle: ToggleStyle {
    let theme: Theme
    /// false: only the switch is drawn (the label stays the accessibility label).
    var showLabel = true
    func makeBody(configuration: Configuration) -> some View {
        let p = theme.palette
        let on = configuration.isOn
        return Button { configuration.isOn.toggle() } label: {
            HStack(spacing: theme.spacing - 4) {
                if showLabel {
                    configuration.label
                    Spacer(minLength: theme.smallGap)
                }
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule().fill((on ? p.accent : p.hairline).swiftUIColor).frame(width: 30, height: 18)
                    // White knob with a hairline and a soft shadow: readable on every accent
                    // (onAccent is black on light accents such as orange).
                    Circle().fill(Color.white).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.black.opacity(0.18), lineWidth: 0.5))
                        .shadow(color: Color.black.opacity(0.25), radius: 0.8, x: 0, y: 0.5)
                        .padding(2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(on ? "вкл" : "выкл")
    }
}

/// Labelled setting row: title, optional explanation, control on the right.
struct SettingRow<Control: View>: View {
    @EnvironmentObject var theme: Theme
    let title: String
    var detail: String?
    let control: Control
    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title; self.detail = detail; self.control = control()
    }
    var body: some View {
        HStack(alignment: .center, spacing: theme.spacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(theme.font(12, weight: .medium)).foregroundColor(theme.palette.text.swiftUIColor)
                if let d = detail {
                    Text(d).font(theme.font(10)).foregroundColor(theme.palette.muted.swiftUIColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: theme.spacing)
            control
        }
    }
}

/// Text field with live validation: the error (red, with icon) blocks the action button; a
/// warning (orange, with icon) does not. `commit` gets the normalised value.
struct ValidatedField: View {
    @EnvironmentObject var theme: Theme
    let label: String
    let placeholder: String
    let actionTitle: String
    var initial: String = ""
    var width: CGFloat? = nil
    /// Optional outside mirror of the draft (live previews).
    var draft: Binding<String>? = nil
    let validate: (String) -> InputCheck<String>
    let commit: (String) -> Void
    @State private var own = ""
    private var text: String { draft?.wrappedValue ?? own }
    private var textBinding: Binding<String> { draft ?? $own }

    var body: some View {
        let p = theme.palette
        let check = validate(text)
        let showError = !text.trimmingCharacters(in: .whitespaces).isEmpty      // live, once typing started
        VStack(alignment: .leading, spacing: theme.smallGap) {
            HStack(spacing: theme.smallGap) {
                TextField(placeholder, text: textBinding)
                    .textFieldStyle(.plain)
                    .font(theme.font(12))
                    .foregroundColor(p.text.swiftUIColor)
                    .padding(.horizontal, theme.spacing - 4).padding(.vertical, theme.rowPadding)
                    .background(RoundedRectangle(cornerRadius: Metrics.smallCornerRadius).fill(p.background.swiftUIColor))
                    .overlay(RoundedRectangle(cornerRadius: Metrics.smallCornerRadius)
                        .stroke((showError && check.error != nil ? p.danger : p.hairline).swiftUIColor, lineWidth: Metrics.hairlineWidth))
                    .frame(maxWidth: width ?? .infinity)
                    .accessibilityLabel(label)
                    .onSubmit(apply)
                Button(actionTitle, action: apply)
                    .buttonStyle(SNButtonStyle(kind: .primary, theme: theme))
                    .fixedSize()
                    .disabled(check.value == nil || text == initial)
                    .opacity(check.value == nil || text == initial ? 0.5 : 1)
            }
            if showError, let e = check.error {
                Note(e, symbol: "xmark.octagon", color: p.danger)
            } else if let w = check.warning, check.value != nil {
                Note(w, symbol: "exclamationmark.triangle", color: p.frozen)
            }
        }
        .onAppear { textBinding.wrappedValue = initial }
    }

    private func apply() {
        guard let v = validate(text).value else { return }
        commit(v)
        if initial.isEmpty { textBinding.wrappedValue = "" }
    }
}

/// ok / warn / fail / unknown as icon + colour + spoken word (never colour alone).
struct LevelIcon: View {
    @EnvironmentObject var theme: Theme
    let level: CheckLevel
    var body: some View {
        let p = theme.palette
        let (sym, col, word): (String, RGB, String) = {
            switch level {
            case .ok: return ("checkmark.circle.fill", p.ok, "в порядке")
            case .warn: return ("exclamationmark.triangle.fill", p.frozen, "предупреждение")
            case .fail: return ("xmark.octagon.fill", p.danger, "проблема")
            case .unknown: return ("questionmark.circle", p.muted, "не проверено")
            }
        }()
        Image(systemName: sym).foregroundColor(col.swiftUIColor).font(.system(size: 13))
            .frame(width: 16)
            .accessibilityLabel(word)
    }
}

/// Removable list item (IPs, countries, networks).
struct RemovableRow: View {
    @EnvironmentObject var theme: Theme
    let title: String
    var detail: String?
    let removeLabel: String
    let remove: () -> Void
    var body: some View {
        let p = theme.palette
        HStack(spacing: theme.spacing - 4) {
            Text(title).font(theme.font(12, weight: .medium)).foregroundColor(p.text.swiftUIColor).textSelection(.enabled)
            if let d = detail { Text(d).font(theme.font(11)).foregroundColor(p.muted.swiftUIColor).lineLimit(1) }
            Spacer(minLength: theme.smallGap)
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.plain).foregroundColor(p.muted.swiftUIColor)
                .accessibilityLabel(removeLabel)
                .help(removeLabel)
        }
        .padding(.vertical, 2)
    }
}
