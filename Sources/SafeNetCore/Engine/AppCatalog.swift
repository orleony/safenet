import Foundation

/// Maps the app ids configured in `Config.apps` / `Config.customApps` to process matchers.
/// Data-driven: presets are plain match strings understood by `AppMatcher` (name, path fragment
/// with "/", or "args:"). Refined in Task 10.
public enum AppCatalog {
    public struct Preset: Equatable {
        public let id: String
        public let name: String
        public let matches: [String]
        public let group: String?
    }

    public static let aiApps = "ai"
    public static let browsersForAI = "browsers-for-ai"

    public static let presets: [Preset] = [
        Preset(id: "claude", name: "Claude", matches: ["/Claude.app/"], group: aiApps),
        Preset(id: "claude-code", name: "Claude Code", matches: ["claude"], group: aiApps),
        Preset(id: "chatgpt", name: "ChatGPT", matches: ["/ChatGPT.app/"], group: aiApps),
        Preset(id: "cursor", name: "Cursor", matches: ["/Cursor.app/"], group: aiApps),
        Preset(id: "perplexity", name: "Perplexity", matches: ["/Perplexity.app/"], group: aiApps),
        Preset(id: "telegram", name: "Telegram", matches: ["/Telegram.app/"], group: nil),
        Preset(id: "chrome", name: "Google Chrome", matches: ["/Google Chrome.app/"], group: browsersForAI),
        Preset(id: "arc", name: "Arc", matches: ["/Arc.app/"], group: browsersForAI),
        Preset(id: "firefox", name: "Firefox", matches: ["/Firefox.app/"], group: browsersForAI),
        // Safari on macOS 13+ runs from a /System cryptex path, which the never-freeze list
        // protects; this entry only catches a Safari copy outside /System (e.g. Technology Preview).
        Preset(id: "safari", name: "Safari", matches: ["/Safari.app/", "/Safari Technology Preview.app/"],
               group: browsersForAI),
    ]

    /// Protected app ids: `apps` in order, then custom app names not already listed.
    public static func appIDs(in config: Config) -> [String] {
        var out: [String] = [], seen = Set<String>()
        for id in config.apps + config.customApps.map({ $0.name }) where seen.insert(id).inserted { out.append(id) }
        return out
    }

    public static func preset(_ id: String) -> Preset? {
        presets.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// Custom app with that name wins over a preset of the same id. Unknown id -> [] (matches nothing).
    public static func matchers(for id: String, in config: Config) -> [AppMatcher] {
        let custom = config.customApps.filter { $0.name == id }
        if !custom.isEmpty { return custom.map { AppMatcher($0) } }
        return preset(id)?.matches.map { AppMatcher(match: $0) } ?? []
    }

    public static func displayName(for id: String) -> String { preset(id)?.name ?? id }
}
