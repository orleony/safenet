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
        return [services(d, allow, config), ipv6(d, allow), dns(d, config), routes(d, allow)]
    }

    static func allowed(_ ip: String, _ cc: String, _ allow: AllowList) -> Bool {
        allow.ips.contains { IPMatcher.matches(ip, entry: $0) } || allow.countries.contains { $0.uppercased() == cc.uppercased() }
    }

    static func place(_ ip: String, _ cc: String) -> String { "\(ip) · \(Format.flag(cc)) \(Format.countryName(cc))" }

    private static func services(_ d: DeepCheckData, _ allow: AllowList, _ c: Config) -> CheckSection {
        var rows: [CheckRow] = []
        let emptyAllow = allow.ips.isEmpty && allow.countries.isEmpty
        let confirmed = Engine.confirmed(d.services.compactMap { $0.answer }, minAgree: max(1, c.minAgree))
        for (i, s) in d.services.enumerated() {
            switch s.outcome {
            case .answer(let a):
                if emptyAllow {
                    rows.append(CheckRow(id: "svc-\(i)", level: .warn, title: s.service, detail: place(a.ip, a.country),
                                         advice: "Список «Разрешено» пуст: ни один адрес не разрешён."))
                } else if allowed(a.ip, a.country, allow) {
                    rows.append(CheckRow(id: "svc-\(i)", level: .ok, title: s.service, detail: place(a.ip, a.country) + " — разрешён"))
                } else if let cf = confirmed, cf.ip == a.ip, allowed(cf.ip, cf.country, allow) {
                    rows.append(CheckRow(id: "svc-\(i)", level: .warn, title: s.service,
                                         detail: place(a.ip, a.country) + " — тот же IP, но база этого сервиса считает страну другой"))
                } else {
                    rows.append(CheckRow(id: "svc-\(i)", level: .fail, title: s.service,
                                         detail: place(a.ip, a.country) + " — не из разрешённых", advice: vpnAdvice))
                }
            case .failed(let why):
                rows.append(CheckRow(id: "svc-\(i)", level: .unknown, title: s.service, detail: "нет ответа (\(why)) — не проверено"))
            case .timedOut:
                rows.append(CheckRow(id: "svc-\(i)", level: .unknown, title: s.service, detail: "не ответил вовремя — не проверено"))
            }
        }
        let answers = d.services.compactMap { $0.answer }
        let need = max(1, c.minAgree)
        if let conf = Engine.confirmed(answers, minAgree: need) {
            let n = answers.filter { $0.ip == conf.ip && $0.country.uppercased() == conf.country.uppercased() }.count
            let countries = Set(answers.map { $0.country.uppercased() })
            let note = countries.count > 1 ? " Сервисы расходятся по стране — так бывает из-за разных баз геолокации." : ""
            rows.append(CheckRow(id: "svc-summary", level: .ok, title: "Итог",
                                 detail: "IP подтверждён: \(n) из \(d.services.count) сервисов назвали \(place(conf.ip, conf.country)).\(note)"))
        } else {
            rows.append(CheckRow(id: "svc-summary", level: .fail, title: "Итог",
                                 detail: "IP не подтверждён: нужно не меньше \(need) одинаковых ответов, получено \(answers.count) ответов.",
                                 advice: "Проверьте подключение. Если сервисы расходятся из-за VPN, уменьшите «Сколько сервисов должны совпасть» в Настройках."))
        }
        return CheckSection(id: "services", title: "IP-сервисы (каждый отдельно)", rows: rows)
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
            row = CheckRow(id: "ipv6", level: .ok, title: "IPv6",
                           detail: "Глобального IPv6-адреса на сетевых интерфейсах нет, IPv6-сервис не ответил: утечки через IPv6 нет.")
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
