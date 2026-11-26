import Foundation
import CryptoKit

/// The sing-box release SafeNet installs (GPL-3.0, https://github.com/SagerNet/sing-box), pinned
/// by version and SHA-256 per architecture. It is not bundled (the universal binary is ~170 MB):
/// downloaded once, for this Mac's architecture only, when the VPN helper is first installed.
/// Keep in step with scripts/fetch-singbox.sh.
public enum SingBoxRelease {
    public static let version = "1.14.4"
    public static let sha256: [String: String] = [
        "arm64": "0d8c7f5ed5d587b0f1a5e9772a708ec3bfa4ac4c9329604b01d8d9c2ba406838",
        "amd64": "eae86b9b033bba50b7c44ab719e4bfac0aca05efd28483390ed3aa510f32db25",
    ]
    public static let maxSize = 64 * 1024 * 1024

    public static var currentArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }

    public static func archiveName(_ arch: String) -> String { "sing-box-\(version)-darwin-\(arch)" }
    public static func url(_ arch: String) -> URL {
        URL(string: "https://github.com/SagerNet/sing-box/releases/download/v\(version)/\(archiveName(arch)).tar.gz")!
    }

    public static func sha256Hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// Ready directory (sing-box, LICENSE, VERSION) for this architecture, downloading and
    /// verifying it when missing. Blocking: call off the main thread.
    public static func ensure(in cache: URL, arch: String = currentArch,
                              download: (URL) -> Result<Data, ProxyLinkError> = SingBoxRelease.download) -> Result<URL, ProxyLinkError> {
        let dir = cache.appendingPathComponent("sing-box-\(version)-\(arch)", isDirectory: true)
        let bin = dir.appendingPathComponent("sing-box")
        if FileManager.default.isExecutableFile(atPath: bin.path),
           (try? String(contentsOf: dir.appendingPathComponent("VERSION"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == version {
            return .success(dir)
        }
        guard let want = sha256[arch] else { return .failure(ProxyLinkError("архитектура \(arch) не поддерживается")) }
        let data: Data
        switch download(url(arch)) {
        case .success(let d): data = d
        case .failure(let e): return .failure(e)
        }
        guard sha256Hex(data) == want else { return .failure(ProxyLinkError("ядро VPN скачалось с другой контрольной суммой — установка отменена")) }
        let fm = FileManager.default
        let tmp = cache.appendingPathComponent(".sing-box-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            let tgz = tmp.appendingPathComponent("a.tgz")
            try data.write(to: tgz)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            p.arguments = ["-xzf", tgz.path, "-C", tmp.path]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { return .failure(ProxyLinkError("архив ядра VPN не распаковался")) }
            let unpacked = tmp.appendingPathComponent(archiveName(arch))
            try? fm.removeItem(at: dir)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.copyItem(at: unpacked.appendingPathComponent("sing-box"), to: bin)
            try? fm.copyItem(at: unpacked.appendingPathComponent("LICENSE"), to: dir.appendingPathComponent("LICENSE"))
            if !fm.fileExists(atPath: dir.appendingPathComponent("LICENSE").path) {
                try Data("GPL-3.0: https://github.com/SagerNet/sing-box/blob/main/LICENSE\n".utf8).write(to: dir.appendingPathComponent("LICENSE"))
            }
            try Data((version + "\n").utf8).write(to: dir.appendingPathComponent("VERSION"))
            chmod(bin.path, 0o755)
            return .success(dir)
        } catch {
            return .failure(ProxyLinkError("не удалось подготовить ядро VPN: \(error.localizedDescription)"))
        }
    }

    /// Plain HTTPS download (GitHub release asset), size-capped.
    public static func download(_ url: URL) -> Result<Data, ProxyLinkError> {
        let sem = DispatchSemaphore(value: 0)
        var out: Result<Data, ProxyLinkError> = .failure(ProxyLinkError("ядро VPN не скачалось"))
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForResource = 300
        URLSession(configuration: cfg).dataTask(with: url) { d, resp, err in
            if let err = err {
                out = .failure(ProxyLinkError("ядро VPN не скачалось с GitHub: \(err.localizedDescription)"))
            } else if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                out = .failure(ProxyLinkError("ядро VPN не скачалось: HTTP \(h.statusCode)"))
            } else if let d = d, d.count <= maxSize {
                out = .success(d)
            }
            sem.signal()
        }.resume()
        sem.wait()
        return out
    }
}
