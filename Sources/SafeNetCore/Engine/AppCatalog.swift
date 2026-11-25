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
        // Claude Code CLI only (never the desktop app, whose executable is also named "Claude"):
        //  - npm install: a node process running .../@anthropic-ai/claude-code/cli.js, started via the
        //    `claude` symlink (`node …/bin/claude`), or retitled to "claude" (process.title rewrites argv);
        //    the "node &&" part keeps editors/pagers that open those files, and `npm i -g …`, out;
        //  - native install: ~/.local/share/claude/ (symlinked from ~/.local/bin/claude);
        //  - Homebrew cask: …/Caskroom/claude-code/<version>/claude;  older local install: ~/.claude/local/.
        Preset(id: "claude-code", name: "Claude Code",
               matches: ["node && args:/@anthropic-ai/claude-code/cli.js", "node && cmd:claude",
                         "/.local/share/claude/", "/Caskroom/claude-code/", "/.claude/local/"], group: aiApps),
        Preset(id: "chatgpt", name: "ChatGPT", matches: ["/ChatGPT.app/"], group: aiApps),
        Preset(id: "codex", name: "Codex", matches: ["/Codex.app/"], group: aiApps),
        Preset(id: "cursor", name: "Cursor", matches: ["/Cursor.app/"], group: aiApps),
        Preset(id: "windsurf", name: "Windsurf", matches: ["/Windsurf.app/"], group: aiApps),
        Preset(id: "vscode", name: "Visual Studio Code", matches: ["/Visual Studio Code.app/"], group: aiApps),
        Preset(id: "perplexity", name: "Perplexity", matches: ["/Perplexity.app/"], group: aiApps),
        Preset(id: "telegram", name: "Telegram", matches: ["/Telegram.app/"], group: nil),
        Preset(id: "discord", name: "Discord", matches: ["/Discord.app/"], group: nil),
        Preset(id: "figma", name: "Figma", matches: ["/Figma.app/"], group: nil),
        Preset(id: "notion", name: "Notion", matches: ["/Notion.app/"], group: nil),
        Preset(id: "slack", name: "Slack", matches: ["/Slack.app/"], group: nil),
        Preset(id: "zoom", name: "Zoom", matches: ["/zoom.us.app/"], group: nil),
        Preset(id: "spotify", name: "Spotify", matches: ["/Spotify.app/"], group: nil),
        Preset(id: "chrome", name: "Google Chrome", matches: ["/Google Chrome.app/"], group: browsersForAI),
        Preset(id: "arc", name: "Arc", matches: ["/Arc.app/"], group: browsersForAI),
        Preset(id: "brave", name: "Brave", matches: ["/Brave Browser.app/"], group: browsersForAI),
        Preset(id: "edge", name: "Microsoft Edge", matches: ["/Microsoft Edge.app/"], group: browsersForAI),
        Preset(id: "yandex", name: "Яндекс Браузер", matches: ["/Yandex.app/"], group: browsersForAI),
        Preset(id: "firefox", name: "Firefox", matches: ["/Firefox.app/"], group: browsersForAI),
        Preset(id: "safari", name: "Safari", matches: [], group: browsersForAI,
               unsupported: "системное приложение: Safari и его веб-процессы запускаются из /System, а системные процессы SafeNet никогда не замораживает"),
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

    /// Dedicated route evidence for the presets with known trace endpoints.
    /// Other apps and custom rules keep the common route check.
    public static func routeHosts(for id: String, in config: Config) -> Set<String>? {
        guard !config.customApps.contains(where: { $0.name == id }) else { return nil }
        switch preset(id)?.id {
        case "claude", "claude-code": return ["claude.ai", "api.anthropic.com"]
        case "chatgpt", "codex": return ["chatgpt.com", "api.openai.com"]
        case "perplexity": return ["www.perplexity.ai"]
        default: return nil
        }
    }
}
