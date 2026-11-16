import Foundation
import ServiceManagement

/// Launch at login via `SMAppService.mainApp` (macOS 13+). Only meaningful inside SafeNet.app;
/// a bare binary reports "off" and refuses to register (no crash).
public enum Autostart {
    public struct Unavailable: Error, CustomStringConvertible {
        public var description: String { "автозапуск работает только из SafeNet.app" }
    }

    public static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    public static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    public static func set(_ on: Bool) throws {
        guard isAvailable else { throw Unavailable() }
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
