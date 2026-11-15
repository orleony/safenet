import SwiftUI
import Combine
import AppKit

/// The real macOS appearance, read from the global AppleInterfaceStyle default ("Dark" when dark,
/// absent otherwise). Unlike @Environment(\.colorScheme) it is unaffected by any scheme the app
/// forces on its own views, so "as system" keeps following macOS after a forced theme is cleared.
public final class SystemAppearance: ObservableObject {
    @Published public private(set) var scheme: ColorScheme
    private let provider: () -> String?
    private var cancellable: AnyCancellable?

    public static func scheme(forStyle style: String?) -> ColorScheme { style == "Dark" ? .dark : .light }

    /// - provider: returns the AppleInterfaceStyle value. changes: fires whenever a re-read is advisable.
    public init(provider: @escaping () -> String?, changes: AnyPublisher<Void, Never>) {
        self.provider = provider
        scheme = SystemAppearance.scheme(forStyle: provider())
        cancellable = changes.receive(on: DispatchQueue.main).sink { [weak self] in self?.refresh() }
    }

    /// Production instance: global defaults plus the system theme-changed notification, with
    /// app activation as a safety net.
    public convenience init() {
        let theme = DistributedNotificationCenter.default()
            .publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification")).map { _ in () }
        let active = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification).map { _ in () }
        self.init(provider: {
            // Re-read from disk: the global domain may have changed behind our cached copy.
            CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
            return CFPreferencesCopyValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication,
                                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
        }, changes: theme.merge(with: active).eraseToAnyPublisher())
    }

    public func refresh() {
        let s = SystemAppearance.scheme(forStyle: provider())
        if s != scheme { scheme = s }
    }
}
