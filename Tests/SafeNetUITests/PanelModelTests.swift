import Foundation
import SafeNetCore
@testable import SafeNetUI

private func ev(_ k: EventKind, _ app: String?, _ d: String) -> Event { Event(kind: k, app: app, detail: d) }

func registerPanelModelTests() {
    // MARK: Allowed IPs / countries

    test("testAllowIPValidation") {
        expectEqual(AllowInput.ip(" 203.0.113.7 ", existing: []).value, "203.0.113.7")
        expectEqual(AllowInput.ip("10.0.0.0/8", existing: []).value, "10.0.0.0/8")
        expectEqual(AllowInput.ip("2001:db8::/32", existing: []).value, "2001:db8::/32")
        for bad in ["", "   ", "abc", "1.2.3", "10.0.0.0/33", "10.0.0.0/", "1.2.3.4/x", "2001:db8::/129", "1.2.3.4 5"] {
            let r = AllowInput.ip(bad, existing: [])
            expect(r.value == nil && r.error != nil, "'\(bad)' must be refused with a message")
        }
        expect(AllowInput.ip("1.2.3.4", existing: ["1.2.3.4"]).error != nil, "duplicate")
        let wide = AllowInput.ip("0.0.0.0/0", existing: [])
        expect(wide.value != nil && wide.warning != nil, "allowed but warned: very broad")
    }

    test("testAllowCountryValidation") {
        expectEqual(AllowInput.country("nl", existing: []).value, "NL")
        expectEqual(AllowInput.country(" De ", existing: []).value, "DE")
        for bad in ["", "N", "NLD", "1A", "XX", "ÑL", "N L"] {
            let r = AllowInput.country(bad, existing: [])
            expect(r.value == nil && r.error != nil, "'\(bad)' must be refused")
        }
        expect(AllowInput.country("nl", existing: ["NL"]).error != nil, "duplicate (case-insensitive)")
        expect(AllowInput.countryChoices.count > 200, "ISO list for the picker")
        expect(AllowInput.countryChoices.contains { $0.code == "NL" })
    }

    // MARK: Custom apps

    test("testCustomAppRefusesEmptyAndShortRules") {
        let base = Config.default
        for bad in ["", "  ", "ab", "args:ab", "args:", "/", " // ", "a/", "cmd:x", "node && ", "args:  x "] {
            let r = CustomAppInput.check(name: "Tool", match: bad, config: base, editing: nil)
            expect(!r.errors.isEmpty, "'\(bad)' must be refused")
        }
        expect(!CustomAppInput.check(name: " ", match: "Tool", config: base, editing: nil).errors.isEmpty, "empty name")
    }

    test("testCustomAppNameCollisions") {
        var c = Config.default
        c.customApps = [CustomApp(name: "Tool", match: "Tool")]
        expect(!CustomAppInput.check(name: "Tool", match: "Other", config: c, editing: nil).errors.isEmpty, "duplicate custom name")
        expect(CustomAppInput.check(name: "Tool", match: "Other", config: c, editing: "Tool").errors.isEmpty, "editing itself is fine")
        expect(!CustomAppInput.check(name: "claude", match: "MyClaude", config: c, editing: nil).errors.isEmpty, "preset id")
    }

    test("testCustomAppWarnsAboutBroadRules") {
        let c = Config.default
        for broad in ["node", "python3", "bash", "/Applications/", "/Users/", ".app/", "args:http", "args:--port"] {
            let r = CustomAppInput.check(name: "X", match: broad, config: c, editing: nil)
            expect(r.errors.isEmpty && !r.warnings.isEmpty, "'\(broad)' allowed but warned: \(r)")
        }
        for fine in ["Telegram", "/Telegram.app/", "args:my-bot.py", "node && cmd:claude"] {
            let r = CustomAppInput.check(name: "X", match: fine, config: c, editing: nil)
            expect(r.errors.isEmpty && r.warnings.isEmpty, "'\(fine)': \(r)")
        }
    }

    test("testCustomAppKindDescription") {
        expect(CustomAppInput.kindText("Telegram").contains("имени"))
        expect(CustomAppInput.kindText("/Foo.app/").contains("пути"))
        expect(CustomAppInput.kindText("args:bot.py").contains("командн"))
    }

    // MARK: Durations

    test("testDurationParsing") {
        expectEqual(DurationInput.parse("20", range: 5...600).value, 20)
        expectEqual(DurationInput.parse(" 1,5 ", range: 1...60).value, 1.5)
        expectEqual(DurationInput.parse("2m", range: 5...600).value, 120)
        expect(DurationInput.parse("abc", range: 5...600).error != nil)
        expect(DurationInput.parse("4", range: 5...600).error?.contains("5") == true, "range in the message")
        expect(DurationInput.parse("601", range: 5...600).error != nil)
        expectEqual(DurationInput.text(20), "20")
        expectEqual(DurationInput.text(1.5), "1.5")
        // Minutes field (pause default): bare number = minutes, suffixes convert, message says минут.
        expectEqual(DurationInput.parse("15", range: 1...1440, unit: .minutes).value, 15)
        expectEqual(DurationInput.parse("2m", range: 1...1440, unit: .minutes).value, 2, "2m is 2 minutes, not 120")
        expectEqual(DurationInput.parse("1h", range: 1...1440, unit: .minutes).value, 60)
        expectEqual(DurationInput.parse("90s", range: 1...1440, unit: .minutes).value, 1.5)
        expect(DurationInput.parse("0", range: 1...1440, unit: .minutes).error?.contains("минут") == true)
        expectEqual(DurationInput.graceRange, 5...600, "one range for common and per-app freeze time")
    }

    test("testAccentHexInput") {
        expectEqual(AccentInput.parse("#12AB34"), "#12ab34")
        expectEqual(AccentInput.parse("12ab34"), "#12ab34")
        expectEqual(AccentInput.parse("#12ab3"), nil)
        expectEqual(AccentInput.parse("blue"), nil)
    }

    // MARK: Trusted networks

    test("testTrustCurrentNetwork") {
        let snap = NetSnapshot(online: true, hasTunnel: false, gatewayIP: "192.168.1.1", gatewayMAC: "A4:2B:B0:1:2:3",
                               subnet: "192.168.1.0/24", interface: "en0", proxy: nil)
        let r = NetworkInput.trust(snap, existing: [])
        expectEqual(r.network, TrustedNetwork(name: "Сеть 192.168.1.1", mac: "a4:2b:b0:01:02:03", ip: "192.168.1.1", subnet: "192.168.1.0/24"))
        expectEqual(r.reason, nil)
        var noMAC = snap; noMAC.gatewayMAC = nil
        expect(NetworkInput.trust(noMAC, existing: []).reason != nil, "no MAC: refused with a reason")
        var vpn = snap; vpn.gatewayIP = nil; vpn.hasTunnel = true
        expect(NetworkInput.trust(vpn, existing: []).reason?.contains("VPN") == true, "full-tunnel VPN hint")
        expect(NetworkInput.trust(nil, existing: []).reason != nil)
        var noSubnet = snap; noSubnet.subnet = nil
        expect(NetworkInput.trust(noSubnet, existing: []).reason != nil)
        expect(NetworkInput.trust(snap, existing: [r.network!]).reason?.contains("уже") == true)
        expect(NetworkInput.rename("  ", index: 0, in: [r.network!]) != nil, "empty name refused")
        expectEqual(NetworkInput.rename("Дом", index: 0, in: [r.network!]), nil)
    }

    // MARK: Journal

    test("testEventDescriptions") {
        expectEqual(EventText.describe(ev(.frozen, "claude", "countryNotAllowed")), "Claude: заморожено — страна не разрешена")
        expectEqual(EventText.describe(ev(.closed, "telegram", "timeout")), "Telegram: закрыто — истёк срок заморозки")
        expectEqual(EventText.describe(ev(.closed, "telegram", "closeNow")), "Telegram: закрыто вручную («Закрыть сейчас»)")
        expectEqual(EventText.describe(ev(.resumed, "claude", "checkPassed")), "Claude: разморожено — проверка пройдена")
        expectEqual(EventText.describe(ev(.paused, nil, "pause")), "Защита на паузе")
        expectEqual(EventText.describe(ev(.paused, nil, "resumeProtection")), "Защита возобновлена")
        expect(EventText.describe(ev(.paused, "claude", "timeoutResume")).hasPrefix("Claude: разморожено по истечении срока"))
        expectEqual(EventText.describe(ev(.leak, "claude", "freezeFailed")), "Claude: не удалось заморозить")
        expectEqual(EventText.describe(ev(.leak, nil, "ipv6Leak")), "Утечка IPv6 мимо VPN")
        expectEqual(EventText.describe(ev(.networkChanged, nil, "networkChanged")), "Сеть изменилась")
        expect(!EventText.describe(ev(.ipChanged, nil, "weird-code")).isEmpty, "unknown detail still readable")
        expect(EventText.filterTitle(.frozen) == "Заморозки")
        expectEqual(Set(EventText.filters.flatMap { $0.kinds }), Set(EventKind.allCases))
    }

    // MARK: Deep check

    test("testDeepCheckRowsNeverFabricateOK") {
        var c = Config.default
        c.allow = AllowList(ips: [], countries: ["NL"])
        let snap = NetSnapshot(online: true, hasTunnel: true, gatewayIP: nil, gatewayMAC: nil, proxy: nil)
        let d = DeepCheckData(
            services: [ServiceResult(service: "a", outcome: .answer(IPAnswer(ip: "1.1.1.1", country: "NL"))),
                       ServiceResult(service: "b", outcome: .answer(IPAnswer(ip: "1.1.1.1", country: "NL"))),
                       ServiceResult(service: "c", outcome: .failed("URLError -1001")),
                       ServiceResult(service: "d", outcome: .timedOut)],
            ipv6: ServiceResult(service: "v6", outcome: .answer(IPAnswer(ip: "2001:db8::1", country: "RU"))),
            routes: [RouteResult(host: "claude.ai", ip: "1.1.1.1", country: "NL", error: nil),
                     RouteResult(host: "chatgpt.com", ip: "5.5.5.5", country: "RU", error: nil),
                     RouteResult(host: "api.openai.com", ip: nil, country: nil, error: "timeout")],
            resolvers: nil, snapshot: snap, finished: Date())
        let sections = DeepCheck.sections(d, config: c)
        let rows = sections.flatMap { $0.rows }
        func level(_ id: String) -> CheckLevel? { rows.first { $0.id == id }?.level }
        expectEqual(level("svc-0"), .ok)
        expectEqual(level("svc-2"), .unknown, "failure is never OK")
        expectEqual(level("svc-3"), .unknown, "timeout is never OK")
        expectEqual(level("svc-summary"), .ok, "2 of 4 agree, min_agree 2")
        expectEqual(level("ipv6"), .fail, "IPv6 exit in RU not allowed")
        expectEqual(level("dns"), .warn, "resolvers unknown -> warning")
        expectEqual(level("route-claude.ai"), .ok)
        expectEqual(level("route-chatgpt.com"), .fail)
        expectEqual(level("route-api.openai.com"), .unknown)
        for r in rows where r.level == .fail { expect(r.advice != nil, "advice for \(r.id)") }
    }

    test("testDeepCheckIPv6AndDNSVariants") {
        var c = Config.default
        c.allow = AllowList(ips: ["1.1.1.1"], countries: [])
        var snap = NetSnapshot(online: true, hasTunnel: true, gatewayIP: nil, gatewayMAC: nil, proxy: nil)
        func d(_ v6: ServiceResult?, _ res: [DNSResolver]?, _ s: NetSnapshot) -> DeepCheckData {
            DeepCheckData(services: [ServiceResult(service: "a", outcome: .answer(IPAnswer(ip: "1.1.1.1", country: "NL")))],
                          ipv6: v6, routes: [], resolvers: res, snapshot: s, finished: Date())
        }
        func lv(_ x: DeepCheckData, _ id: String) -> CheckLevel? { DeepCheck.sections(x, config: c).flatMap { $0.rows }.first { $0.id == id }?.level }
        let failed = ServiceResult(service: "v6", outcome: .failed("x"))
        expectEqual(lv(d(failed, [], snap), "ipv6"), .warn, "no global IPv6 and no answer: only inferred, never a plain OK")
        expect(DeepCheck.sections(d(failed, [], snap), config: c).flatMap { $0.rows }.first { $0.id == "ipv6" }?.detail
            .contains("по-видимому") == true)
        snap.hasGlobalIPv6 = true
        expectEqual(lv(d(failed, [], snap), "ipv6"), .unknown, "IPv6 present but the service failed: unknown")
        let tunnelDNS = [DNSResolver(address: "10.8.0.1", interface: "utun3", scoped: false)]
        expectEqual(lv(d(failed, tunnelDNS, snap), "dns"), .ok)
        let leak = [DNSResolver(address: "8.8.8.8", interface: "en0", scoped: false)]
        expectEqual(lv(d(failed, leak, snap), "dns"), .warn, "warn mode")
        c.dnsCheck = .block
        expectEqual(lv(d(failed, leak, snap), "dns"), .fail, "block mode")
        c.dnsCheck = .off
        expectEqual(lv(d(failed, leak, snap), "dns"), .unknown, "check off: not evaluated, not OK")
        expectEqual(lv(d(nil, nil, snap), "svc-summary"), .fail, "1 answer < min_agree 2")
    }

    test("testDeepCheckSummaryConfirmedButNotAllowed") {
        var c = Config.default
        c.allow = AllowList(ips: [], countries: ["NL"])
        let snap = NetSnapshot(online: true, hasTunnel: true, gatewayIP: nil, gatewayMAC: nil, proxy: nil)
        let ru = ServiceResult(service: "a", outcome: .answer(IPAnswer(ip: "5.5.5.5", country: "RU")))
        let data = DeepCheckData(services: [ru, ru], ipv6: nil, routes: [], resolvers: nil, snapshot: snap, finished: Date())
        let row = DeepCheck.sections(data, config: c).flatMap { $0.rows }.first { $0.id == "svc-summary" }
        expectEqual(row?.level, .fail, "confirmed but not allowed is not green")
        expect(row?.detail.contains("Не из разрешённых") == true, row?.detail ?? "")
        expect(row?.advice != nil)
        c.allow = AllowList()
        expectEqual(DeepCheck.sections(data, config: c).flatMap { $0.rows }.first { $0.id == "svc-summary" }?.level, .warn,
                    "empty allow list: warning")
    }

    test("testConfigEditCustomAppRenameMovesRules") {
        var c = Config.default
        ConfigEdit.saveCustom(&c, original: nil, name: " Tool ", match: " Tool ")
        expectEqual(c.customApps, [CustomApp(name: "Tool", match: "Tool")])
        c.appRules["Tool"] = AllowList(countries: ["NL"]); c.appGrace["Tool"] = 60
        ConfigEdit.saveCustom(&c, original: "Tool", name: "Tool2", match: "args:tool.py")
        expectEqual(c.customApps, [CustomApp(name: "Tool2", match: "args:tool.py")])
        expectEqual(c.appRules["Tool2"], AllowList(countries: ["NL"])); expectEqual(c.appRules["Tool"], nil)
        expectEqual(c.appGrace["Tool2"], 60); expectEqual(c.appGrace["Tool"], nil)
        ConfigEdit.deleteCustom(&c, "Tool2")
        expectEqual(c.customApps, []); expectEqual(c.appRules, [:]); expectEqual(c.appGrace, [:])
    }

    test("testConfigEditCommonRulesToggle") {
        var c = Config.default
        c.allow = AllowList(ips: ["1.2.3.4"], countries: ["NL"]); c.grace = 20
        ConfigEdit.setUseCommonRules(&c, "claude", false)
        expectEqual(c.appRules["claude"], c.allow, "own list starts as a copy (no instant freeze)")
        ConfigEdit.setUseCommonRules(&c, "claude", true)
        expectEqual(c.appRules["claude"], nil)
        ConfigEdit.setUseCommonGrace(&c, "claude", false)
        expectEqual(c.appGrace["claude"], 20)
        ConfigEdit.setUseCommonGrace(&c, "claude", true)
        expectEqual(c.appGrace["claude"], nil)
    }

    test("testDeepCheckCountryFromFirstDatabaseAndSplitRouting") {
        var c = Config.default
        c.allow = AllowList(ips: [], countries: ["NL"])
        let ip = { (x: String) in IPAnswer(ip: x, country: "") }
        var d = DeepCheckData(
            services: [ServiceResult(service: "a", outcome: .answer(ip("195.133.9.79"))),
                       ServiceResult(service: "b", outcome: .answer(ip("195.133.9.79"))),
                       ServiceResult(service: "c", outcome: .failed("лимит запросов (HTTP 429)")),
                       ServiceResult(service: "d", outcome: .answer(ip("46.138.81.39")))],
            ipv6: nil, routes: [], resolvers: [], snapshot: NetSnapshot(online: true, hasTunnel: true, gatewayIP: nil, gatewayMAC: nil, proxy: nil),
            finished: Date())
        expectEqual(DeepCheck.majorityIP(d.services.compactMap { $0.answer }), "195.133.9.79")
        d.geoIP = "195.133.9.79"
        d.geo = [GeoAnswer(source: "ipinfo.io", outcome: .failure(.rateLimited(retryAfter: nil))),
                 GeoAnswer(source: "api.country.is", outcome: .success("NL")),
                 GeoAnswer(source: "ifconfig.co", outcome: .success("CZ"))]
        let rows = DeepCheck.sections(d, config: c).flatMap { $0.rows }
        let lv = { (id: String) in rows.first { $0.id == id }?.level }
        expectEqual(lv("svc-0"), .ok); expectEqual(lv("svc-2"), .unknown)
        expectEqual(lv("svc-3"), .warn, "another address = split routing, not a failure by itself")
        expectEqual(lv("svc-summary"), .ok, "NL from the first database that answered")
        expect(rows.first { $0.id == "svc-summary" }?.detail.contains("api.country.is") == true)
        expectEqual(lv("svc-split"), .warn)
        expectEqual(lv("geo-0"), .unknown); expectEqual(lv("geo-1"), .ok); expectEqual(lv("geo-2"), .warn, "databases disagree")
        d.geo = []
        expectEqual(DeepCheck.sections(d, config: c).flatMap { $0.rows }.first { $0.id == "svc-summary" }?.level, .unknown,
                    "no database answered: unknown, never green")
    }

    test("testCustomAppWarnsForSystemOnlyRule") {
        let base = Config.default
        let sys: (String) -> Bool = { $0 == "/System/Applications/Notes.app" }
        let r = CustomAppInput.check(name: "Заметки", match: "Notes", config: base, editing: nil, fileExists: sys)
        expect(r.errors.isEmpty, "\(r)")
        expect(r.warnings.contains(CustomAppInput.systemOnlyText), "\(r)")
        let p = CustomAppInput.check(name: "TE", match: "/System/Applications/TextEdit.app", config: base, editing: nil, fileExists: { _ in false })
        expect(p.warnings.contains(CustomAppInput.systemOnlyText), "\(p)")
        let both: (String) -> Bool = { $0 == "/System/Applications/Notes.app" || $0 == "/Applications/Notes.app" }
        expect(!CustomAppInput.check(name: "N", match: "Notes", config: base, editing: nil, fileExists: both).warnings
            .contains(CustomAppInput.systemOnlyText), "a user-installed copy can be protected")
        expect(!CustomAppInput.check(name: "T", match: "Telegram", config: base, editing: nil, fileExists: { _ in false }).warnings
            .contains(CustomAppInput.systemOnlyText))
    }
}
