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
        /// Non-nil: cannot be protected; the reason is shown in the UI and the Guard ignores the id.
        public let unsupported: String?

        public init(id: String, name: String, matches: [String], group: String?, unsupported: String? = nil) {
            self.id = id; self.name = name; self.matches = matches; self.group = group; self.unsupported = unsupported
        }
    }

    public static let aiApps = "ai"
    public static let browsersForAI = "browsers-for-ai"

    public static let presets: [Preset] = [
        // Desktop app only: the CLI never lives inside Claude.app.
        Preset(id: "claude", name: "Claude", matches: ["/Claude.app/"], group: aiApps),
        // Claude Code CLI only: npm install runs `node …/@anthropic-ai/claude-code/cli.js`; the
        // native install runs from ~/.local/share/claude/ (symlinked from ~/.local/bin/claude) and
        // the older local install from ~/.claude/local/. No name rule: "claude" would also match
        // the desktop app's executable.
        Preset(id: "claude-code", name: "Claude Code",
               matches: ["args:@anthropic-ai/claude-code", "args:claude-code/cli.js",
                         "/.local/share/claude/", "/.claude/local/"], group: aiApps),
        Preset(id: "chatgpt", name: "ChatGPT", matches: ["/ChatGPT.app/"], group: aiApps),
        Preset(id: "cursor", name: "Cursor", matches: ["/Cursor.app/"], group: aiApps),
        Preset(id: "perplexity", name: "Perplexity", matches: ["/Perplexity.app/"], group: aiApps),
        Preset(id: "telegram", name: "Telegram", matches: ["/Telegram.app/"], group: nil),
        Preset(id: "chrome", name: "Google Chrome", matches: ["/Google Chrome.app/"], group: browsersForAI),
        Preset(id: "arc", name: "Arc", matches: ["/Arc.app/"], group: browsersForAI),
        Preset(id: "firefox", name: "Firefox", matches: ["/Firefox.app/"], group: browsersForAI),
        Preset(id: "safari", name: "Safari", matches: [], group: browsersForAI,
               unsupported: "system app: Safari and its web processes run from /System, which is never frozen"),
    ]

    /// Presets the UI may offer for selection.
    public static var selectablePresets: [Preset] { presets.filter { $0.unsupported == nil } }

    /// Protected app ids: `apps` in order, then custom app names not already listed. Ids of
    /// unsupported presets are left out (unless a custom app of that name exists).
    public static func appIDs(in config: Config) -> [String] {
        var out: [String] = [], seen = Set<String>()
        let custom = Set(config.customApps.map { $0.name })
        for id in config.apps + config.customApps.map({ $0.name }) where seen.insert(id).inserted {
            if !custom.contains(id), preset(id)?.unsupported != nil { continue }
            out.append(id)
        }
        return out
    }

    public static func preset(_ id: String) -> Preset? {
        presets.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// Custom app with that name wins over a preset of the same id. Unknown or unsupported id -> []
    /// (matches nothing).
    public static func matchers(for id: String, in config: Config) -> [AppMatcher] {
        let custom = config.customApps.filter { $0.name == id }
        if !custom.isEmpty { return custom.map { AppMatcher($0) } }
        guard let p = preset(id), p.unsupported == nil else { return [] }
        return p.matches.map { AppMatcher(match: $0) }
    }

    public static func displayName(for id: String) -> String { preset(id)?.name ?? id }
}
