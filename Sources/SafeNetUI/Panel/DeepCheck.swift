import Foundation
import SafeNetCore

/// Raw results of the on-demand deep check ("Проверка" tab). Only the existing endpoints are
/// contacted: the IP services, the IPv6-only service and `/cdn-cgi/trace` of the five AI hosts.
public struct DeepCheckData: Equatable {
    /// IPv4 IP services, one result each (failures and timeouts included).
    public var services: [ServiceResult]
    /// The IPv6-only service (nil = not asked).
    public var ipv6: ServiceResult?
    public var routes: [RouteResult]
    /// nil = could not be read.
    public var resolvers: [DNSResolver]?
    public var snapshot: NetSnapshot
    public var finished: Date
    /// Every GeoIP database's answer about `geoIP`, in priority order (the first valid one is
    /// the country SafeNet uses).
    public var geo: [GeoAnswer] = []
    /// The address the databases were asked about (the one most services saw), nil = none.
    public var geoIP: String?

    public init(services: [ServiceResult], ipv6: ServiceResult?, routes: [RouteResult], resolvers: [DNSResolver]?,
                snapshot: NetSnapshot, finished: Date) {
        self.services = services; self.ipv6 = ipv6; self.routes = routes; self.resolvers = resolvers
        self.snapshot = snapshot; self.finished = finished
    }
}

/// ok = verified; warn = probably fine / needs attention; fail = problem; unknown = could not be
/// verified (a failure or timeout is NEVER shown as ok).
public enum CheckLevel: Equatable { case ok, warn, fail, unknown }

public struct CheckRow: Equatable, Identifiable {
    public var id: String
    public var level: CheckLevel
    public var title: String
    public var detail: String
    /// What to turn on in the VPN / change in SafeNet (nil when nothing to do).
    public var advice: String?
}

public struct CheckSection: Equatable, Identifiable {
    public var id: String
    public var title: String
    public var rows: [CheckRow]
}

public enum DeepCheck {
    static let vpnAdvice = "Включите VPN (или kill switch в самом VPN) либо добавьте этот адрес/страну во вкладке «Разрешено»."

    public static func sections(_ d: DeepCheckData, config: Config) -> [CheckSection] {
        let allow = Engine.leakAllow(config)
        return [services(d, allow, config), countries(d), ipv6(d, allow), dns(d, config), routes(d, allow)]
    }

    static func allowed(_ ip: String, _ cc: String, _ allow: AllowList) -> Bool {
        allow.ips.contains { IPMatcher.matches(ip, entry: $0) } || allow.countries.contains { $0.uppercased() == cc.uppercased() }
    }

    static func place(_ ip: String, _ cc: String) -> String { "\(ip) · \(Format.flag(cc)) \(Format.countryName(cc))" }

    /// The address most IPv4 answers name (ties: none).
    public static func majorityIP(_ answers: [IPAnswer]) -> String? {
        var n: [String: Int] = [:]
        for a in answers where !a.ip.contains(":") { n[a.ip, default: 0] += 1 }
        guard let top = n.values.max(), n.values.filter({ $0 == top }).count == 1 else { return nil }
        return n.first { $0.value == top }?.key
    }

    /// The country SafeNet uses for `d.geoIP`: the first valid database answer.
    static func primaryCountry(_ d: DeepCheckData) -> (country: String, source: String)? {
        d.geo.first { $0.country != nil }.map { ($0.country!, $0.source) }
    }

    private static func services(_ d: DeepCheckData, _ allow: AllowList, _ c: Config) -> CheckSection {
        var rows: [CheckRow] = []
        let emptyAllow = allow.ips.isEmpty && allow.countries.isEmpty
        let disabled = Set(IPServiceSet.ipv4Hosts).subtracting(c.ipServices)
        let participating = d.services.filter { !disabled.contains($0.service) }
        let answers = Engine.quorumAnswers(participating.compactMap { $0.answer })
        let need = max(1, c.minAgree)
        var votes: [String: Int] = [:]
        for a in answers { votes[a.ip, default: 0] += 1 }
        let quorum = votes.filter { $0.value >= need }
        let confirmedIP = quorum.count == 1 ? quorum.first?.key : nil
        for (i, s) in d.services.enumerated() {
            let off = disabled.contains(s.service) ? " (выключен в Настройках)" : ""
            switch s.outcome {
            case .answer(let a):
                if confirmedIP == nil || a.ip == confirmedIP {
                    rows.append(CheckRow(id: "svc-\(i)", level: confirmedIP == nil ? .unknown : .ok, title: s.service, detail: a.ip + off))
                } else {
                    rows.append(CheckRow(id: "svc-\(i)", level: .warn, title: s.service,
                                         detail: "\(a.ip) — другой адрес: запросы к этому сервису идут мимо VPN (раздельная маршрутизация)\(off)"))
                }
            case .failed(let why):
                rows.append(CheckRow(id: "svc-\(i)", level: .unknown, title: s.service, detail: "нет ответа (\(why)) — не проверено\(off)"))
            case .timedOut:
                rows.append(CheckRow(id: "svc-\(i)", level: .unknown, title: s.service, detail: "не ответил вовремя — не проверено\(off)"))
            }
        }
        guard let ip = confirmedIP else {
            rows.append(CheckRow(id: "svc-summary", level: .fail, title: "Итог",
                                 detail: "IP не подтверждён: нужно не меньше \(need) одинаковых адресов, получено ответов: \(answers.count).",
                                 advice: "Проверьте подключение. Если сервисы видят разные адреса из-за VPN, уменьшите «Сколько сервисов должны совпасть» в Настройках."))
            return CheckSection(id: "services", title: "Внешний IP (каждый сервис отдельно)", rows: rows)
        }
        let n = votes[ip] ?? 0
        let primary = d.geoIP == ip ? primaryCountry(d) : nil
        let cc = primary?.country ?? answers.first { $0.ip == ip && !$0.country.isEmpty }?.country ?? ""
        let place = cc.isEmpty ? ip + " · страна неизвестна" : DeepCheck.place(ip, cc) + (primary.map { " (по базе \($0.source))" } ?? "")
        let base = "IP подтверждён: \(n) из \(participating.count) включённых сервисов назвали \(ip). \(place)."
        if emptyAllow {
            rows.append(CheckRow(id: "svc-summary", level: .warn, title: "Итог", detail: base + " Список «Разрешено» пуст.",
                                 advice: "Укажите разрешённые страны или IP во вкладке «Разрешено»."))
        } else if allowed(ip, cc, allow) {
            rows.append(CheckRow(id: "svc-summary", level: .ok, title: "Итог", detail: base + " Разрешён."))
        } else if cc.isEmpty {
            rows.append(CheckRow(id: "svc-summary", level: .unknown, title: "Итог", detail: base + " Ни одна база не назвала страну — разрешён ли адрес, неизвестно.",
                                 advice: "Повторите проверку позже: базы стран временно ограничивают запросы."))
        } else {
            rows.append(CheckRow(id: "svc-summary", level: .fail, title: "Итог", detail: base + " Не из разрешённых.", advice: vpnAdvice))
        }
        let others = Set(answers.map { $0.ip }).subtracting([ip])
        if !others.isEmpty {
            rows.append(CheckRow(id: "svc-split", level: .warn, title: "Раздельная маршрутизация",
                                 detail: "Часть запросов идёт мимо VPN (\(others.sorted().joined(separator: ", "))) — так настроен VPN. Пропускать ли приложения, решает проверка маршрута до ИИ-сервисов ниже.",
                                 advice: c.routeCheck ? nil : "Включите «Проверять маршрут до ИИ-сервисов» в Настройках, чтобы обход VPN до них тоже замораживал приложения."))
        }
        return CheckSection(id: "services", title: "Внешний IP (каждый сервис отдельно)", rows: rows)
    }

    private static func countries(_ d: DeepCheckData) -> CheckSection {
        guard let ip = d.geoIP else {
            return CheckSection(id: "geo", title: "Базы стран", rows: [
                CheckRow(id: "geo-none", level: .unknown, title: "Базы стран", detail: "Адрес не определён — спрашивать базы не о чем."),
            ])
        }
        let primary = primaryCountry(d)
        let rows = d.geo.enumerated().map { i, g -> CheckRow in
            switch g.outcome {
            case .success(let cc):
                if primary?.source == g.source {
                    return CheckRow(id: "geo-\(i)", level: .ok, title: g.source, detail: "\(Format.flag(cc)) \(Format.countryName(cc)) — используется (первая база по порядку)")
                }
                let same = cc == primary?.country
                return CheckRow(id: "geo-\(i)", level: same ? .ok : .warn, title: g.source,
                                detail: "\(Format.flag(cc)) \(Format.countryName(cc))" + (same ? "" : " — базы расходятся, так бывает с адресами VPN; учитывается первая база"))
            case .failure(let e):
                return CheckRow(id: "geo-\(i)", level: .unknown, title: g.source, detail: "нет ответа (\(e.reason))")
            }
        }
        return CheckSection(id: "geo", title: "Страна адреса \(ip) (базы по порядку)", rows: rows)
    }

    private static func ipv6(_ d: DeepCheckData, _ allow: AllowList) -> CheckSection {
        let row: CheckRow
        if let a = d.ipv6?.answer {
            if detectIPv6Leak(answers: [a], allow: allow) {
                row = CheckRow(id: "ipv6", level: .fail, title: "IPv6", detail: "IPv6 выходит мимо VPN: \(place(a.ip, a.country))",
                               advice: "Включите в VPN туннелирование IPv6 или блокировку IPv6 (часто называется «IPv6 leak protection»), либо отключите IPv6 в настройках сети.")
            } else {
                row = CheckRow(id: "ipv6", level: .ok, title: "IPv6", detail: "IPv6 выходит через разрешённый адрес: \(place(a.ip, a.country))")
            }
        } else if !d.snapshot.hasGlobalIPv6 {
            row = CheckRow(id: "ipv6", level: .warn, title: "IPv6",
                           detail: "Глобального IPv6-адреса на сетевых интерфейсах нет, IPv6-сервис не ответил: утечки через IPv6, по-видимому, нет (вывод по косвенным признакам, не проверено ответом сервиса).")
        } else {
            row = CheckRow(id: "ipv6", level: .unknown, title: "IPv6",
                           detail: "IPv6-адрес есть, но IPv6-сервис не ответил — проверить не удалось.",
                           advice: "Повторите проверку позже. Если VPN не туннелирует IPv6, включите в нём блокировку IPv6.")
        }
        return CheckSection(id: "ipv6", title: "IPv6", rows: [row])
    }

    private static func dns(_ d: DeepCheckData, _ c: Config) -> CheckSection {
        let advice = "Включите в VPN «DNS через VPN» / защиту от утечек DNS или укажите DNS-серверы VPN."
        let row: CheckRow
        if c.dnsCheck == .off {
            row = CheckRow(id: "dns", level: .unknown, title: "DNS", detail: "Проверка DNS выключена в Настройках — не проверено.")
        } else if !d.snapshot.hasTunnel {
            row = CheckRow(id: "dns", level: .unknown, title: "DNS",
                           detail: "VPN-туннель не найден, сравнивать DNS не с чем. Если VPN работает как системный прокси, DNS-запросы могут идти мимо него.")
        } else if let res = d.resolvers {
            let list = res.isEmpty ? "серверов нет" : res.map { $0.address + ($0.interface.map { " (\($0))" } ?? "") }.joined(separator: ", ")
            if detectDNSLeak(resolvers: res, hasTunnel: true) {
                row = CheckRow(id: "dns", level: c.dnsCheck == .block ? .fail : .warn, title: "DNS",
                               detail: "Возможна утечка DNS мимо VPN: \(list)", advice: advice)
            } else if res.isEmpty {
                row = CheckRow(id: "dns", level: .warn, title: "DNS", detail: "Список DNS-серверов пуст — проверить нельзя.", advice: advice)
            } else {
                row = CheckRow(id: "dns", level: .ok, title: "DNS", detail: "DNS-серверы через VPN: \(list)")
            }
        } else {
            row = CheckRow(id: "dns", level: .warn, title: "DNS", detail: "Не удалось прочитать DNS-серверы — утечку проверить нельзя.",
                           advice: advice)
        }
        return CheckSection(id: "dns", title: "DNS", rows: [row])
    }

    private static func routes(_ d: DeepCheckData, _ allow: AllowList) -> CheckSection {
        let rows = d.routes.map { r -> CheckRow in
            if let ip = r.ip, r.error == nil {
                let cc = r.country ?? ""
                if allowed(ip, cc, allow) {
                    return CheckRow(id: "route-\(r.host)", level: .ok, title: r.host, detail: "видит \(place(ip, cc)) — разрешён")
                }
                return CheckRow(id: "route-\(r.host)", level: .fail, title: r.host, detail: "видит \(place(ip, cc)) — не из разрешённых",
                                advice: "Трафик к \(r.host) идёт мимо VPN: добавьте этот сервис в туннель (раздельное туннелирование, правила маршрутизации) или включите полный туннель.")
            }
            return CheckRow(id: "route-\(r.host)", level: .unknown, title: r.host, detail: "не ответил — не проверено")
        }
        return CheckSection(id: "routes", title: "Маршрут до ИИ-сервисов", rows: rows)
    }
}
