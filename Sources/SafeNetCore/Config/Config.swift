import Foundation

public struct CustomApp: Equatable {
    public var name: String
    /// Process name, path fragment (contains "/"), or "args:<fragment>" (matched later by AppMatcher).
    public var match: String
    public init(name: String, match: String) { self.name = name; self.match = match }
}

public struct AllowList: Equatable {
    public var ips: [String]
    public var countries: [String]
    public init(ips: [String] = [], countries: [String] = []) { self.ips = ips; self.countries = countries }
}

public struct TrustedNetwork: Equatable {
    public var name: String
    public var mac: String
    public var ip: String
    public var subnet: String
    public init(name: String, mac: String, ip: String, subnet: String) {
        self.name = name; self.mac = mac; self.ip = ip; self.subnet = subnet
    }
}

public enum TimeoutAction: String, Equatable { case close, keepFrozen = "keep_frozen", resume }
public enum DNSCheckMode: String, Equatable { case warn, block, off }
public enum ThemeChoice: String, Equatable { case light, dark, system }
public enum MenubarDisplay: String, Equatable { case ip, country, icon }
public enum Density: String, Equatable { case compact, comfortable }
public enum FontStyle: String, Equatable { case system, mono }

public struct ConfigError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public var description: String { "config error: \(message)" }
    init(_ m: String) { message = m }
}

/// Settings model. Source of truth is config.yaml (snake_case keys); see `init(yaml:)` / `toYAML()`.
public struct Config: Equatable {
    public var apps: [String]
    public var customApps: [CustomApp]
    public var allow: AllowList
    public var appRules: [String: AllowList]
    public var appGrace: [String: TimeInterval]
    public var grace: TimeInterval
    public var closeTimeout: TimeInterval
    public var checkInterval: TimeInterval
    public var minAgree: Int
    public var onTimeout: TimeoutAction
    public var blockWhenOffline: Bool
    public var checkIPv6: Bool
    public var dnsCheck: DNSCheckMode
    public var routeCheck: Bool
    public var theme: ThemeChoice
    public var accent: String
    public var density: Density
    public var fontStyle: FontStyle
    public var menubar: MenubarDisplay
    public var trustedNetworks: [TrustedNetwork]
    /// Default length of "Пауза" (YAML `pause_default`), 15 min.
    public var pauseDefault: TimeInterval = 900
    /// Time zone used to DISPLAY times (journal, pause end): "system" or an IANA id (YAML `timezone`).
    public var timezone: String = "system"

    public static let `default` = Config(
        apps: [], customApps: [], allow: AllowList(), appRules: [:], appGrace: [:],
        grace: 20, closeTimeout: 5, checkInterval: 5, minAgree: 2, onTimeout: .close,
        blockWhenOffline: true, checkIPv6: true, dnsCheck: .warn, routeCheck: true,
        theme: .system, accent: "blue", density: .comfortable, fontStyle: .system,
        menubar: .ip, trustedNetworks: [])

    public init(apps: [String], customApps: [CustomApp], allow: AllowList, appRules: [String: AllowList],
                appGrace: [String: TimeInterval], grace: TimeInterval, closeTimeout: TimeInterval,
                checkInterval: TimeInterval, minAgree: Int, onTimeout: TimeoutAction, blockWhenOffline: Bool,
                checkIPv6: Bool, dnsCheck: DNSCheckMode, routeCheck: Bool, theme: ThemeChoice, accent: String,
                density: Density, fontStyle: FontStyle, menubar: MenubarDisplay, trustedNetworks: [TrustedNetwork]) {
        self.apps = apps; self.customApps = customApps; self.allow = allow; self.appRules = appRules
        self.appGrace = appGrace; self.grace = grace; self.closeTimeout = closeTimeout
        self.checkInterval = checkInterval; self.minAgree = minAgree; self.onTimeout = onTimeout
        self.blockWhenOffline = blockWhenOffline; self.checkIPv6 = checkIPv6; self.dnsCheck = dnsCheck
        self.routeCheck = routeCheck; self.theme = theme; self.accent = accent; self.density = density
        self.fontStyle = fontStyle; self.menubar = menubar; self.trustedNetworks = trustedNetworks
    }

    // MARK: YAML -> Config (missing keys take defaults; wrong types / bad values throw)

    public init(yaml: YAMLValue) throws {
        var c = Config.default
        if case .null = yaml { self = c; return }
        guard case .map = yaml else { throw ConfigError("top level must be a mapping") }

        if let v = yaml["apps"] { c.apps = try Config.strings(v, "apps") }
        if let v = yaml["custom_apps"] {
            c.customApps = try Config.items(v, "custom_apps").map {
                CustomApp(name: try Config.str($0["name"], "custom_apps.name"),
                          match: try Config.str($0["match"], "custom_apps.match"))
            }
        }
        if let v = yaml["allow"] { c.allow = try Config.allowList(v, "allow") }
        // Keys are canonicalised here, in file order: when `Claude` and `claude` both appear, the
        // FIRST one in the file wins (deterministic and visible to whoever edits the file).
        let customNames = Set(c.customApps.map { $0.name })
        func canon(_ k: String) -> String { customNames.contains(k) ? k : (AppCatalog.preset(k)?.id ?? k) }
        if let v = yaml["app_rules"] {
            for e in try Config.entries(v, "app_rules") {
                let r = try Config.allowList(e.value, "app_rules.\(e.key)")
                if c.appRules[canon(e.key)] == nil { c.appRules[canon(e.key)] = r }
            }
        }
        if let v = yaml["app_grace"] {
            for e in try Config.entries(v, "app_grace") {
                let g = try Config.duration(e.value, "app_grace.\(e.key)")
                if c.appGrace[canon(e.key)] == nil { c.appGrace[canon(e.key)] = g }
            }
        }
        if let v = yaml["grace"] { c.grace = try Config.duration(v, "grace") }
        if let v = yaml["close_timeout"] { c.closeTimeout = try Config.duration(v, "close_timeout") }
        if let v = yaml["check_interval"] { c.checkInterval = try Config.duration(v, "check_interval") }
        if let v = yaml["min_agree"] { c.minAgree = try Config.int(v, "min_agree") }
        if let v = yaml["on_timeout"] { c.onTimeout = try Config.enumValue(v, "on_timeout") }
        if let v = yaml["block_when_offline"] { c.blockWhenOffline = try Config.bool(v, "block_when_offline") }
        if let v = yaml["check_ipv6"] { c.checkIPv6 = try Config.bool(v, "check_ipv6") }
        if let v = yaml["dns_check"] { c.dnsCheck = try Config.enumValue(v, "dns_check") }
        if let v = yaml["route_check"] { c.routeCheck = try Config.bool(v, "route_check") }
        if let v = yaml["theme"] { c.theme = try Config.enumValue(v, "theme") }
        if let v = yaml["accent"] { c.accent = try Config.str(v, "accent") }
        if let v = yaml["density"] { c.density = try Config.enumValue(v, "density") }
        if let v = yaml["font_style"] { c.fontStyle = try Config.enumValue(v, "font_style") }
        if let v = yaml["menubar"] { c.menubar = try Config.enumValue(v, "menubar") }
        if let v = yaml["pause_default"] { c.pauseDefault = try Config.duration(v, "pause_default") }
        if let v = yaml["timezone"] { c.timezone = try Config.str(v, "timezone") }
        if let v = yaml["trusted_networks"] {
            c.trustedNetworks = try Config.items(v, "trusted_networks").map {
                TrustedNetwork(name: try Config.str($0["name"], "trusted_networks.name"),
                               mac: try Config.str($0["mac"], "trusted_networks.mac"),
                               ip: try Config.str($0["ip"], "trusted_networks.ip"),
                               subnet: try Config.str($0["subnet"], "trusted_networks.subnet"))
            }
        }
        c.normalisePresetIDs()
        try c.validate()
        self = c
    }

    /// Value checks shared by the YAML loader and in-app changes (`Engine.updateConfig`).
    public func validate() throws {
        func finite(_ v: Double, _ k: String) throws { guard v.isFinite else { throw ConfigError("\(k) must be a finite number") } }
        try finite(grace, "grace"); try finite(closeTimeout, "close_timeout"); try finite(checkInterval, "check_interval")
        try finite(pauseDefault, "pause_default")
        guard grace > 0 else { throw ConfigError("grace must be > 0") }
        guard closeTimeout >= 0 else { throw ConfigError("close_timeout must be >= 0") }
        guard checkInterval > 0 else { throw ConfigError("check_interval must be > 0") }
        guard pauseDefault > 0 else { throw ConfigError("pause_default must be > 0") }
        guard timezone == "system" || TimeZone(identifier: timezone) != nil else { throw ConfigError("timezone must be \"system\" or a time zone id like Europe/Moscow") }
        guard minAgree >= 1 else { throw ConfigError("min_agree must be >= 1") }
        for (k, g) in appGrace where !(g > 0) || !g.isFinite { throw ConfigError("app_grace.\(k) must be > 0") }
    }

    /// Preset ids in their canonical (lowercase) form, duplicates dropped, also as keys of
    /// `app_rules` / `app_grace` (a hand-edited `Claude` would otherwise never toggle off).
    /// Custom app names are kept exactly. The YAML loader already resolves key collisions in file
    /// order (first wins); for a Config built in code, colliding keys resolve in sorted key order.
    public mutating func normalisePresetIDs() {
        let custom = Set(customApps.map { $0.name })
        func canon(_ id: String) -> String { custom.contains(id) ? id : (AppCatalog.preset(id)?.id ?? id) }
        var seen = Set<String>(), out: [String] = []
        for id in apps.map(canon) where seen.insert(id).inserted { out.append(id) }
        apps = out
        var rules: [String: AllowList] = [:]
        for k in appRules.keys.sorted() where rules[canon(k)] == nil { rules[canon(k)] = appRules[k] }
        appRules = rules
        var grace: [String: TimeInterval] = [:]
        for k in appGrace.keys.sorted() where grace[canon(k)] == nil { grace[canon(k)] = appGrace[k] }
        appGrace = grace
    }

    // MARK: Config -> YAML

    public func toYAML() -> YAMLValue {
        func list(_ a: [String]) -> YAMLValue { .list(a.map { .string($0) }) }
        func allowMap(_ a: AllowList) -> YAMLValue {
            .map([YAMLEntry("ips", list(a.ips)), YAMLEntry("countries", list(a.countries))])
        }
        return .map([
            YAMLEntry("apps", list(apps)),
            YAMLEntry("custom_apps", .list(customApps.map {
                .map([YAMLEntry("name", .string($0.name)), YAMLEntry("match", .string($0.match))]) })),
            YAMLEntry("allow", allowMap(allow)),
            YAMLEntry("app_rules", .map(appRules.keys.sorted().map { YAMLEntry($0, allowMap(appRules[$0]!)) })),
            YAMLEntry("app_grace", .map(appGrace.keys.sorted().map { YAMLEntry($0, Config.fmt(appGrace[$0]!)) })),
            YAMLEntry("grace", Config.fmt(grace)),
            YAMLEntry("close_timeout", Config.fmt(closeTimeout)),
            YAMLEntry("check_interval", Config.fmt(checkInterval)),
            YAMLEntry("min_agree", .number(Double(minAgree))),
            YAMLEntry("on_timeout", .string(onTimeout.rawValue)),
            YAMLEntry("block_when_offline", .bool(blockWhenOffline)),
            YAMLEntry("check_ipv6", .bool(checkIPv6)),
            YAMLEntry("dns_check", .string(dnsCheck.rawValue)),
            YAMLEntry("route_check", .bool(routeCheck)),
            YAMLEntry("theme", .string(theme.rawValue)),
            YAMLEntry("accent", .string(accent)),
            YAMLEntry("density", .string(density.rawValue)),
            YAMLEntry("font_style", .string(fontStyle.rawValue)),
            YAMLEntry("menubar", .string(menubar.rawValue)),
            YAMLEntry("pause_default", Config.fmt(pauseDefault)),
            YAMLEntry("timezone", .string(timezone)),
            YAMLEntry("trusted_networks", .list(trustedNetworks.map {
                .map([YAMLEntry("name", .string($0.name)), YAMLEntry("mac", .string($0.mac)),
                      YAMLEntry("ip", .string($0.ip)), YAMLEntry("subnet", .string($0.subnet))]) })),
        ])
    }

    // MARK: Helpers

    private static func fmt(_ t: TimeInterval) -> YAMLValue {
        .string(t == t.rounded() && abs(t) < 1e15 ? "\(Int64(t))s" : "\(t)s")
    }

    private static func str(_ v: YAMLValue?, _ key: String) throws -> String {
        switch v {
        case .string(let s)?: return s
        case .number(let d)? where abs(d) < 1e15: return d == d.rounded() ? String(Int64(d)) : String(d)
        case .bool(let b)?: return b ? "true" : "false"
        default: throw ConfigError("'\(key)' must be a string")
        }
    }

    private static func bool(_ v: YAMLValue, _ key: String) throws -> Bool {
        if case .bool(let b) = v { return b }
        throw ConfigError("'\(key)' must be true or false")
    }

    private static func int(_ v: YAMLValue, _ key: String) throws -> Int {
        if case .number(let d) = v, d == d.rounded(), abs(d) < 1e9 { return Int(d) }
        throw ConfigError("'\(key)' must be an integer")
    }

    /// Accepts 20, 20s, 1.5s, 5m, 2h.
    private static func duration(_ v: YAMLValue, _ key: String) throws -> TimeInterval {
        let limit = 1e9   // ~31 years; rejects absurd values that could overflow later conversions
        if case .number(let d) = v, abs(d) <= limit { return d }
        if case .string(let s) = v {
            var t = s.trimmingCharacters(in: .whitespaces), mult = 1.0
            if let last = t.last, "smh".contains(last) {
                mult = last == "s" ? 1 : last == "m" ? 60 : 3600
                t.removeLast()
            }
            if let d = Double(t), d.isFinite, abs(d * mult) <= limit { return d * mult }
        }
        throw ConfigError("'\(key)' must be a duration like 20s, 5m or a number of seconds")
    }

    private static func enumValue<E: RawRepresentable>(_ v: YAMLValue, _ key: String) throws -> E where E.RawValue == String {
        if case .string(let s) = v, let e = E(rawValue: s) { return e }
        throw ConfigError("'\(key)' has an unknown value")
    }

    private static func strings(_ v: YAMLValue, _ key: String) throws -> [String] {
        if case .null = v { return [] }
        guard case .list(let l) = v else { throw ConfigError("'\(key)' must be a list") }
        return try l.map { try str($0, key) }
    }

    private static func items(_ v: YAMLValue, _ key: String) throws -> [YAMLValue] {
        if case .null = v { return [] }
        guard case .list(let l) = v else { throw ConfigError("'\(key)' must be a list") }
        for i in l { guard case .map = i else { throw ConfigError("'\(key)' items must be mappings") } }
        return l
    }

    private static func entries(_ v: YAMLValue, _ key: String) throws -> [YAMLEntry] {
        if case .null = v { return [] }
        guard case .map(let m) = v else { throw ConfigError("'\(key)' must be a mapping") }
        return m
    }

    private static func allowList(_ v: YAMLValue, _ key: String) throws -> AllowList {
        if case .null = v { return AllowList() }
        guard case .map = v else { throw ConfigError("'\(key)' must be a mapping with ips/countries") }
        return AllowList(ips: try v["ips"].map { try strings($0, key + ".ips") } ?? [],
                         countries: try v["countries"].map { try strings($0, key + ".countries") } ?? [])
    }
}
