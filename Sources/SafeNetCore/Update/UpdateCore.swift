import Foundation
import CryptoKit

// Self-updater, pure part: versions, the signed release manifest, the decision "is there a newer
// build I may install". Nothing here touches the network or the disk except `sha256Hex(file:)`.
//
// Release format (published by scripts/release.sh as GitHub release assets):
//   update.json      the manifest (`UpdateManifest`), exact bytes
//   update.json.sig  base64 Ed25519 signature of those bytes, made with the release key
//   SafeNet-<v>.zip  the app archive; its SHA-256 and size are in the manifest
// The app embeds only the PUBLIC key (Info.plist `SafeNetUpdatePublicKey`). A manifest that does not
// verify, or an archive whose hash differs, is never installed.

/// "1.2.3" (one to three numeric parts, missing parts are 0). Compared numerically.
public struct AppVersion: Comparable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        let raw = t.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(raw.count) else { return nil }
        var out: [Int] = []
        for p in raw {
            guard !p.isEmpty, p.utf8.count <= 6, p.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let n = Int(p) else { return nil }
            out.append(n)
        }
        while out.count < 3 { out.append(0) }
        parts = out
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    /// CFBundleVersion for this version: major*10000 + minor*100 + patch (minor/patch < 100).
    public var buildNumber: Int? {
        guard parts[1] < 100, parts[2] < 100 else { return nil }
        return parts[0] * 10_000 + parts[1] * 100 + parts[2]
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
    public static func == (a: AppVersion, b: AppVersion) -> Bool { a.parts == b.parts }
}

public struct UpdateManifest: Codable, Equatable {
    public var version: String
    /// https URL of the zip.
    public var url: String
    /// Lowercase hex SHA-256 of the zip.
    public var sha256: String
    public var size: Int
    /// Lowest macOS the build runs on ("13.0"); nil = no constraint.
    public var minimumSystem: String?
    public var notes: String?

    enum CodingKeys: String, CodingKey {
        case version, url, sha256, size, notes
        case minimumSystem = "minimum_system"
    }

    public init(version: String, url: String, sha256: String, size: Int, minimumSystem: String? = nil, notes: String? = nil) {
        self.version = version; self.url = url; self.sha256 = sha256; self.size = size
        self.minimumSystem = minimumSystem; self.notes = notes
    }

    /// Largest archive accepted (the app is ~3 MB).
    public static let maxSize = 200 * 1024 * 1024

    public var appVersion: AppVersion? { AppVersion(version) }
    public var downloadURL: URL? { URL(string: url) }

    /// Strict decode: unknown version format, non-https URL, malformed hash or size -> throws.
    public static func decode(_ data: Data) throws -> UpdateManifest {
        guard data.count <= 64 * 1024 else { throw UpdateError.badManifest("слишком большой") }
        let m: UpdateManifest
        do { m = try JSONDecoder().decode(UpdateManifest.self, from: data) } catch {
            throw UpdateError.badManifest("не JSON или нет нужных полей")
        }
        guard m.appVersion != nil else { throw UpdateError.badManifest("версия «\(m.version.prefix(20))»") }
        guard let u = m.downloadURL, u.scheme == "https", u.host?.isEmpty == false else {
            throw UpdateError.badManifest("адрес архива должен быть https")
        }
        guard m.sha256.utf8.count == 64, m.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw UpdateError.badManifest("sha256")
        }
        guard m.size > 0, m.size <= maxSize else { throw UpdateError.badManifest("размер архива") }
        if let s = m.minimumSystem, AppVersion(s) == nil { throw UpdateError.badManifest("minimum_system") }
        return m
    }
}

public enum UpdateError: Error, Equatable, CustomStringConvertible {
    case notConfigured
    case badManifest(String)
    case badSignature
    case network(String)
    case badArchive(String)
    case install(String)

    public var description: String {
        switch self {
        case .notConfigured: return "обновления не настроены в этой сборке (нет ключа проверки)"
        case .badManifest(let m): return "описание обновления испорчено: \(m)"
        case .badSignature: return "подпись обновления не прошла проверку — обновление отклонено"
        case .network(let m): return "нет связи с сервером обновлений: \(m)"
        case .badArchive(let m): return "архив обновления отклонён: \(m)"
        case .install(let m): return "обновление не установлено: \(m)"
        }
    }
}

public enum UpdateSignature {
    /// Ed25519 (`Curve25519.Signing`) over the exact manifest bytes. Base64 inputs; whitespace
    /// around them (a trailing newline in the .sig file) is ignored. Anything malformed -> false.
    public static func verify(_ data: Data, signature: String, publicKey: String) -> Bool {
        let ws = CharacterSet.whitespacesAndNewlines
        guard let sig = Data(base64Encoded: signature.trimmingCharacters(in: ws)), sig.count == 64,
              let raw = Data(base64Encoded: publicKey.trimmingCharacters(in: ws)), raw.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return key.isValidSignature(sig, for: data)
    }
}

public enum UpdateDecision {
    /// Verified manifest of a build newer than `current` that runs on `system`; nil when there is
    /// nothing to install (same or older version, or it needs a newer macOS). Throws when the
    /// signature or the manifest is bad. The signature is checked BEFORE the manifest is parsed.
    public static func evaluate(manifest data: Data, signature: String, publicKey: String,
                                current: AppVersion, system: AppVersion) throws -> UpdateManifest? {
        guard !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw UpdateError.notConfigured }
        guard UpdateSignature.verify(data, signature: signature, publicKey: publicKey) else { throw UpdateError.badSignature }
        let m = try UpdateManifest.decode(data)
        guard let v = m.appVersion, v > current else { return nil }
        if let min = m.minimumSystem.flatMap(AppVersion.init), system < min { return nil }
        return m
    }

    public static var systemVersion: AppVersion {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return AppVersion("\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)") ?? AppVersion("13.0")!
    }
}

/// Lowercase hex SHA-256 of a file, read in 1 MB chunks; nil when it cannot be read.
public func sha256Hex(file: URL) -> String? {
    guard let h = FileHandle(forReadingAtPath: file.path) else { return nil }
    defer { try? h.close() }
    var hasher = SHA256()
    while true {
        let chunk = h.readData(ofLength: 1 << 20)
        if chunk.isEmpty { break }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// `updates` in config.yaml: install by itself, only tell, or never contact the update server.
public enum UpdateMode: String, Equatable { case auto, notify, off }
