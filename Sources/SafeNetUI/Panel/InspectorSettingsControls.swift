import SwiftUI
import SafeNetCore

struct InspectorSettingsGroup<Content: View>: View {
    @EnvironmentObject private var theme: Theme
    var title: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.smallGap) {
            if let title {
                Text(title).font(theme.font(13, weight: .semibold)).foregroundColor(p.text.swiftUIColor)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(p.surface.swiftUIColor, in: RoundedRectangle(cornerRadius: Metrics.smallCornerRadius))
        }
    }
}

struct InspectorSettingsDivider: View {
    @EnvironmentObject private var theme: Theme

    var body: some View {
        Rectangle().fill(theme.palette.hairline.swiftUIColor.opacity(0.55))
            .frame(height: Metrics.hairlineWidth)
            .padding(.horizontal, theme.padding)
            .accessibilityHidden(true)
    }
}

struct InspectorSettingRow<Control: View>: View {
    @EnvironmentObject private var theme: Theme
    let title: String
    var detail: String?
    @ViewBuilder var control: () -> Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control
    }

    var body: some View {
        SettingRow(title, detail: detail, control: control)
            .padding(.horizontal, theme.padding)
            .padding(.vertical, theme.rowPadding)
            .frame(minHeight: theme.rowPadding * 2 + 30)
    }
}

/// Steps are applied to the latest configuration on the engine queue, so rapid clicks compose
/// even when the published UI snapshot still shows the previous value.
struct InspectorDurationSetting {
    let key: WritableKeyPath<Config, TimeInterval>
    let range: ClosedRange<Double>
    let unit: DurationInput.Unit

    private var factor: Double { unit == .minutes ? 60 : 1 }

    func value(in config: Config) -> Double { config[keyPath: key] / factor }

    func set(_ number: Double, in config: inout Config) {
        config[keyPath: key] = number * factor
    }

    func step(by amount: Double, in config: inout Config) {
        let next = value(in: config) + amount
        set(min(range.upperBound, max(range.lowerBound, next)), in: &config)
    }
}

struct InspectorDurationRow: View {
    @EnvironmentObject private var theme: Theme
    @State private var draft: String?
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let unit: DurationInput.Unit
    let detail: String?
    let save: (Double) -> Void
    let step: (Double) -> Void

    var body: some View {
        let p = theme.palette
        let savedValue = DurationInput.text(value)
        let enteredValue = draft ?? savedValue
        let result = DurationInput.parse(enteredValue, range: range, unit: unit)
        let changed = enteredValue != savedValue
        let text = Binding(get: { draft ?? savedValue }, set: { draft = $0 })
        let units = unit == .seconds ? "с" : "мин"

        VStack(alignment: .leading, spacing: 0) {
            InspectorSettingRow(title, detail: detail) {
                HStack(spacing: 6) {
                    TextField(title, text: text)
                        .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                        .font(theme.font(12).monospacedDigit())
                        .foregroundColor(p.text.swiftUIColor)
                        .frame(width: 45)
                        .accessibilityLabel("\(title), \(unit == .seconds ? "секунды" : "минуты")")
                        .onSubmit { if changed, let number = result.value { apply(number) } }
                    Text(units).font(theme.font(11)).foregroundColor(p.muted.swiftUIColor)
                        .accessibilityHidden(true)

                    if changed, let number = result.value, number != value {
                        Button { apply(number) } label: { Image(systemName: "checkmark") }
                            .buttonStyle(.borderless)
                            .foregroundColor(p.accent.swiftUIColor)
                            .accessibilityLabel("Применить: \(title)")
                            .help("Применить (Return)")
                    } else {
                        Stepper(title, onIncrement: { adjust(1) }, onDecrement: { adjust(-1) })
                            .labelsHidden().controlSize(.mini).fixedSize()
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(p.background.swiftUIColor, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder((changed && result.error != nil ? p.danger : p.hairline).swiftUIColor,
                                      lineWidth: Metrics.hairlineWidth)
                        .allowsHitTesting(false)
                }
                .fixedSize()
            }

            if changed, let error = result.error {
                Note(error, symbol: "exclamationmark.circle", color: p.danger)
                    .padding(.horizontal, theme.padding).padding(.bottom, theme.rowPadding)
            }
        }
    }

    private func adjust(_ amount: Double) {
        draft = nil
        step(amount)
    }

    private func apply(_ number: Double) {
        draft = nil
        save(number)
    }
}
