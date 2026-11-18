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

    /// Longest usable unix-socket path (sun_path is 104 bytes on macOS, including the NUL).
    public static let maxSocketPath = 103

    /// The CLI socket: `<dir>/safenet.sock` (same directory logic as the config, so a test
    /// `SAFENET_CONFIG_DIR` never shares a socket with the real app). When that path would not
    /// fit into sun_path, a short per-user fallback `<tmp>/safenet-<uid>/<hash of dir>.sock` is used
    /// (the server creates that directory 0700 and refuses one it does not own). Server and client
    /// compute the same path from the same environment.
    public var socketPath: String { socketPath(tempDir: NSTemporaryDirectory()) }

    func socketPath(tempDir: String) -> String {
        let direct = dir.appendingPathComponent("safenet.sock").path
        if direct.utf8.count <= AppPaths.maxSocketPath { return direct }
        var h: UInt64 = 0xcbf29ce484222325                       // FNV-1a of the directory path
        for b in dir.path.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        let name = "safenet-\(getuid())"
        let file = String(format: "%016llx.sock", h)
        let tmp = (tempDir as NSString).appendingPathComponent(name) + "/" + file
        return tmp.utf8.count <= AppPaths.maxSocketPath ? tmp : "/tmp/\(name)/\(file)"
    }

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
