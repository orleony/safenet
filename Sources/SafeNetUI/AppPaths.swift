import Foundation
import SafeNetCore

/// Where SafeNet keeps its files. `SAFENET_CONFIG_DIR` overrides the directory (manual tests use a
/// temporary one so the real ~/Library/Application Support/SafeNet is never touched).
public struct AppPaths: Equatable {
    public let dir: URL
    public var config: URL { dir.appendingPathComponent("config.yaml") }
    /// Freeze journal; the watchdog child gets the same path.
    public var journal: URL { dir.appendingPathComponent("frozen.json") }
    public var events: URL { dir.appendingPathComponent("events.jsonl") }

    public init(dir: URL) { self.dir = dir }

    public static func from(environment env: [String: String]) -> AppPaths {
        if let d = env["SAFENET_CONFIG_DIR"], !d.isEmpty {
            return AppPaths(dir: URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true))
        }
        return AppPaths(dir: ConfigStore.defaultURL.deletingLastPathComponent())
    }

    public func createDirectory() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

/// Test mode: `SAFENET_FAKE_IP=ip,CC` replaces every IP service (and the route probe) with a fixed
/// answer; `SAFENET_FAKE_OFFLINE=1` makes the network look offline. Used to demonstrate freezing
/// without a VPN. The window shows a "ТЕСТОВЫЙ РЕЖИМ" badge.
public struct TestMode: Equatable {
    public var fakeAnswer: IPAnswer?
    public var offline: Bool

    public init(fakeAnswer: IPAnswer?, offline: Bool) { self.fakeAnswer = fakeAnswer; self.offline = offline }

    /// nil = normal mode. A malformed SAFENET_FAKE_IP is ignored (normal mode) unless offline is set.
    public static func from(environment env: [String: String]) -> TestMode? {
        var answer: IPAnswer?
        if let raw = env["SAFENET_FAKE_IP"] {
            let parts = raw.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, HTTPIPService.isValidIP(parts[0]),
               parts[1].utf8.count == 2, parts[1].uppercased().utf8.allSatisfy({ $0 >= 65 && $0 <= 90 }) {
                answer = IPAnswer(ip: parts[0], country: parts[1].uppercased())
            }
        }
        let offline = env["SAFENET_FAKE_OFFLINE"] == "1"
        guard answer != nil || offline else { return nil }
        return TestMode(fakeAnswer: answer, offline: offline)
    }
}
