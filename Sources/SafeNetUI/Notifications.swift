import Foundation
import UserNotifications
import SafeNetCore

/// macOS notifications. `UNUserNotificationCenter` crashes in a binary without a bundle, so it is
/// only touched inside a .app (bundle identifier present); otherwise the text goes to the log.
/// Authorization is requested lazily, with the first notification.
public final class Notifier {
    private var asked = false
    private let enabled: Bool

    public init(bundleIdentifier: String? = Bundle.main.bundleIdentifier) { enabled = bundleIdentifier != nil }

    public func post(_ n: NoticeText) {
        guard enabled else { NSLog("SafeNet notice: %@ — %@", n.title, n.body); return }
        let center = UNUserNotificationCenter.current()
        let send = {
            let c = UNMutableNotificationContent()
            c.title = n.title
            c.body = n.body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
        if asked { send(); return }
        asked = true
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in if ok { send() } }
    }
}

public struct NoticeText: Equatable {
    public var title: String
    public var body: String
    public init(title: String, body: String) { self.title = title; self.body = body }

    public static func configError(_ message: String) -> NoticeText {
        NoticeText(title: "SafeNet: ошибка в config.yaml", body: "Работаю на прежних настройках. \(message)")
    }
}

/// Decides which state changes deserve a notification. Text holds only the reason / app names,
/// never IPs or other personal data.
///  - frozen: once per episode, and not for the instant precautionary freeze on a network change
///    (it lasts until the next check, usually a second; the real reason follows if it persists);
///  - closed: once per close;
///  - back to ok: "Защита восстановлена" only after an announced freeze/close, or after a pause.
public struct NoticeTracker {
    /// A freeze/close was announced since the last ok (so "restored" is worth saying).
    private var announced = false
    /// The current freeze episode was announced.
    private var frozenAnnounced = false
    private var last: GuardState?

    public init() {}

    public mutating func update(_ new: GuardState, closedApps: [String] = []) -> NoticeText? {
        defer { last = new }
        switch new {
        case .frozen(_, let r, _):
            guard !frozenAnnounced, r != .networkChanged else { return nil }
            announced = true; frozenAnnounced = true
            return NoticeText(title: "SafeNet", body: "Приложения заморожены: \(Format.reason(r))")
        case .closed:
            frozenAnnounced = false                  // a relaunch freezes anew: announce it
            if case .closed? = last { return nil }
            announced = true
            let names = closedApps.isEmpty ? "" : ": " + closedApps.joined(separator: ", ")
            return NoticeText(title: "SafeNet", body: "Приложения закрыты\(names)")
        case .paused:
            announced = false; frozenAnnounced = false
            return nil
        case .ok:
            let wasPaused: Bool = { if case .paused? = last { return true }; return false }()
            defer { announced = false; frozenAnnounced = false }
            return announced || wasPaused ? NoticeText(title: "SafeNet", body: "Защита восстановлена") : nil
        }
    }
}
