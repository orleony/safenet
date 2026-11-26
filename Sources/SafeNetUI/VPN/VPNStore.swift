import Foundation
import SafeNetCore

/// Where the servers come from: one pasted link, or a subscription URL (its links are kept so the
/// list works offline and between refreshes).
public struct VPNSource: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable { case link, subscription }
    public var id: String
    public var kind: Kind
    /// Subscription URL (kind .subscription).
    public var url: String?
    public var links: [String]
    public var title: String?
    public var updated: Date?
    public var info: SubscriptionInfo?

    public init(id: String = UUID().uuidString, kind: Kind, url: String? = nil, links: [String], title: String? = nil,
                updated: Date? = nil, info: SubscriptionInfo? = nil) {
        self.id = id; self.kind = kind; self.url = url; self.links = links; self.title = title; self.updated = updated; self.info = info
    }

    /// Parsed servers (links that no longer parse are skipped).
    public var profiles: [VPNProfile] { links.compactMap { try? ProxyLink.parse($0) } }

    public var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        if kind == .subscription, let u = url.flatMap({ URL(string: $0)?.host }) { return u }
        return profiles.first?.name ?? "Сервер"
    }
}

/// vpn.json (0600, next to config.yaml): server links contain credentials, so they are not in
/// config.yaml.
public struct VPNSettings: Codable, Equatable {
    public var sources: [VPNSource] = []
    /// `VPNProfile.id` of the chosen server.
    public var selected: String?
    public var mode: VPNMode = .all
    /// The user switched the VPN on (it is reconnected at launch; while on and down, apps freeze).
    public var enabled = false
    public init() {}

    public var allProfiles: [VPNProfile] { sources.flatMap { $0.profiles } }
    public var selectedProfile: VPNProfile? {
        let all = allProfiles
        return all.first { $0.id == selected }
    }

    /// Keep the selection valid: a vanished server falls back to the first one of any source.
    public mutating func fixSelection() {
        let all = allProfiles
        if let s = selected, all.contains(where: { $0.id == s }) { return }
        selected = all.first?.id
    }
}

public final class VPNStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> VPNSettings {
        guard let d = try? Data(contentsOf: url), let s = try? JSONDecoder.vpn.decode(VPNSettings.self, from: d) else { return VPNSettings() }
        return s
    }

    @discardableResult
    public func save(_ s: VPNSettings) -> Bool {
        let e = JSONEncoder.vpn
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? e.encode(s) else { return false }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".vpn.json.tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: d, attributes: [.posixPermissions: 0o600]) else { return false }
        if rename(tmp.path, url.path) != 0 { try? FileManager.default.removeItem(at: tmp); return false }
        chmod(url.path, 0o600)
        return true
    }
}
