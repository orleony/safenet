import Foundation
import ServiceManagement

/// Launch at login via `SMAppService.mainApp` (macOS 13+). Only meaningful inside SafeNet.app;
/// a bare binary reports "off" and refuses to register (no crash).
public enum Autostart {
    public struct Unavailable: Error, CustomStringConvertible {
        public var description: String { "автозапуск работает только из SafeNet.app" }
    }

    /// What the switch shows. `requiresApproval`: registered, but the user still has to allow it
    /// in System Settings → General → Login Items (common on newer macOS); it is not running at
    /// login until then, so it must not look like plain "on" nor like "off".
    public enum State: Equatable { case unavailable, off, on, requiresApproval }

    public static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// Pure mapping (tests).
    public static func state(_ status: SMAppService.Status, available: Bool) -> State {
        guard available else { return .unavailable }
        switch status {
        case .enabled: return .on
        case .requiresApproval: return .requiresApproval
        default: return .off
        }
    }

    public static var current: State { state(isAvailable ? SMAppService.mainApp.status : .notRegistered, available: isAvailable) }

    /// The switch is on when registered (approved or waiting for approval).
    public static var isEnabled: Bool { [.on, .requiresApproval].contains(current) }

    public static func set(_ on: Bool) throws {
        guard isAvailable else { throw Unavailable() }
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    /// System Settings → General → Login Items.
    public static func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}
