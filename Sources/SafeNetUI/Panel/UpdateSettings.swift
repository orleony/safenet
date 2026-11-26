import SwiftUI
import SafeNetCore

/// Texts of the update state (Settings card and the menu line).
public enum UpdateText {
    public static func status(_ s: UpdateState) -> String {
        switch s {
        case .disabled(let why): return "Обновления недоступны: \(why)."
        case .idle: return "Проверка ещё не выполнялась."
        case .checking: return "Проверяю, есть ли новая версия…"
        case .upToDate(let at): return "Установлена последняя версия (проверено в \(Format.clock(at)))."
        case .available(let v): return "Доступна версия \(v)."
        case .downloading(let v): return "Загружаю версию \(v)…"
        case .waiting(let v): return "Версия \(v) загружена и проверена. Установится, когда защита в норме: ничего не заморожено, не закрыто и нет паузы."
        case .installing(let v): return "Устанавливаю версию \(v): SafeNet перезапустится через несколько секунд."
        case .failed(let m): return "Не получилось: \(m)."
        }
    }

    /// The line in the menu window, only when there is something to act on or to know.
    public static func menuLine(_ s: UpdateState) -> String? {
        switch s {
        case .available(let v): return "Доступна версия \(v)"
        case .waiting(let v): return "Версия \(v) установится, когда защита будет в норме"
        case .installing(let v): return "Устанавливаю версию \(v)…"
        default: return nil
        }
    }

    public static func modeDetail(_ m: UpdateMode) -> String {
        switch m {
        case .auto: return "Раз в сутки SafeNet проверяет новую версию на GitHub, сверяет подпись и ставит её сам, когда ничего не заморожено."
        case .notify: return "Раз в сутки проверяет и только сообщает о новой версии; устанавливается по кнопке «Обновить»."
        case .off: return "SafeNet не обращается к серверу обновлений. Проверить можно кнопкой ниже."
        }
    }
}

/// "Обновления" card in Settings.
struct UpdateSettings: View {
    @ObservedObject var model: AppState
    @EnvironmentObject var theme: Theme

    var body: some View {
        let p = theme.palette
        let c = model.config
        Card {
            CardTitle("Обновления")
            SettingRow("Новые версии", detail: UpdateText.modeDetail(c.updates)) {
                Segmented(options: [(UpdateMode.auto, "Ставить сами"), (.notify, "Только сообщать"), (.off, "Выключено")],
                          selection: c.updates) { v in model.update { $0.updates = v } }
            }
            Note(UpdateText.status(model.updateState),
                 symbol: isError ? "xmark.octagon" : "arrow.triangle.2.circlepath",
                 color: isError ? p.danger : nil)
            HStack(spacing: theme.spacing - 4) {
                if case .available(let v) = model.updateState {
                    Button("Обновить до \(v)") { model.installUpdate() }
                        .buttonStyle(SNButtonStyle(kind: .primary, theme: theme)).fixedSize()
                }
                Button("Проверить сейчас") { model.checkForUpdates() }
                    .buttonStyle(SNButtonStyle(kind: .secondary, theme: theme)).fixedSize()
                    .disabled(!canCheck)
            }
        }
    }

    private var isError: Bool { if case .failed = model.updateState { return true }; return false }

    private var canCheck: Bool {
        switch model.updateState {
        case .disabled, .checking, .downloading, .installing: return false
        default: return true
        }
    }
}
