import Foundation
import SafeNetCore

/// Text of `status` (Russian, no secrets: no process arguments, no config content).
public enum CLIStatusText {
    public static func make(status s: EngineStatus, config: Config, configPath: String, testMode: TestMode?,
                            configReadOnly: Bool, now: Date = Date()) -> String {
        var lines: [String] = []
        let apps = AppCatalog.appIDs(in: config)
        lines.append(stateLine(s.state, hasApps: !apps.isEmpty, now: now))
        if testMode != nil {
            lines.append("ТЕСТОВЫЙ РЕЖИМ" + (configReadOnly ? " (настройки не сохраняются)" : ""))
        }
        if let c = s.confirmed {
            lines.append("IP: \(c.ip) (\(c.country.isEmpty ? "страна неизвестна" : c.country.uppercased()))")
        } else if s.answers.isEmpty {
            lines.append("IP: нет ответа" + (s.snapshot?.online == false ? " (нет сети)" : ""))
        } else {
            var seen: [String] = []
            for a in s.answers { let t = "\(a.ip) (\(a.country.uppercased()))"; if !seen.contains(t) { seen.append(t) } }
            lines.append("IP: не подтверждён; ответы сервисов: " + seen.joined(separator: ", "))
        }
        if let snap = s.snapshot { lines.append("VPN-туннель: " + (snap.hasTunnel ? "да" : "нет")) }
        if apps.isEmpty {
            lines.append("Защищаемые приложения: нет")
        } else {
            lines.append("Защищаемые приложения:")
            for id in apps {
                lines.append("  \(AppCatalog.displayName(for: id)): " + appState(id, s))
            }
        }
        lines.append("Конфиг: \(configPath)")
        return lines.joined(separator: "\n")
    }

    static func stateLine(_ st: GuardState, hasApps: Bool, now: Date) -> String {
        switch st {
        case .ok: return hasApps ? "Защита включена" : "Нет защищаемых приложений"
        case .frozen(_, let reason, let deadline):
            var t = "Приложения заморожены (\(Format.reason(reason))"
            if let d = deadline { t += ", закрытие через \(max(0, Int(d.timeIntervalSince(now).rounded(.up)))) с" }
            return t + ")"
        case .closed: return "Закрыто"
        case .paused(let until):
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"
            return "Пауза до \(f.string(from: until))"
        }
    }

    static func appState(_ id: String, _ s: EngineStatus) -> String {
        if s.unprotectableApps.contains(id) { return "системное приложение — не защищается" }
        if s.freezeFailedApps.contains(id) { return "не удалось заморозить" }
        if s.notRunningApps.contains(id) { return "не запущено" }
        if s.frozenApps.contains(id) { return "заморожено" }
        if s.closedApps.contains(id) { return "закрыто" }
        if s.releasedApps.contains(id) { return "освобождено до следующей проверки" }
        return "под защитой"
    }
}

/// Executes CLI commands inside the running app. `perform` runs a closure on the engine queue
/// (never blocks the caller); results are delivered through `reply`, from whatever queue.
public final class CLIService {
    private let perform: (@escaping (Engine) -> Void) -> Void
    private let paths: AppPaths
    private let testMode: TestMode?
    private let configReadOnly: Bool
    private let openPanel: (@escaping (Bool) -> Void) -> Void
    private let version: String

    /// - openPanel: opens the panel on the main thread, reports whether it could.
    public init(perform: @escaping (@escaping (Engine) -> Void) -> Void, paths: AppPaths, testMode: TestMode?,
                configReadOnly: Bool, openPanel: @escaping (@escaping (Bool) -> Void) -> Void, version: String) {
        self.perform = perform; self.paths = paths; self.testMode = testMode
        self.configReadOnly = configReadOnly; self.openPanel = openPanel; self.version = version
    }

    public func handle(_ c: CLICommand, reply: @escaping (IPCResponse) -> Void) {
        switch c {
        case .version: reply(IPCResponse(ok: true, text: "SafeNet \(version)"))
        case .config: reply(IPCResponse(ok: true, text: paths.config.path))
        case .panel:
            openPanel { ok in reply(ok ? IPCResponse(ok: true, text: "Окно SafeNet открыто")
                                       : .error("Не удалось открыть окно SafeNet")) }
        case .status:
            perform { [paths, testMode, configReadOnly] e in
                reply(IPCResponse(ok: true, text: CLIStatusText.make(
                    status: e.status, config: e.config, configPath: paths.config.path, testMode: testMode,
                    configReadOnly: configReadOnly)))
            }
        case .allow(let target):
            perform { e in reply(CLIService.allow(target, engine: e)) }
        }
    }

    /// Engine queue. The same change the UI makes, through `Engine.updateConfig` (test-mode write
    /// refusal and the broken-file backup apply).
    static func allow(_ target: String?, engine e: Engine) -> IPCResponse {
        enum Kind { case ip(String), country(String) }
        let kind: Kind, warning: String?
        if let t = target {
            if t.utf8.count == 2 && !t.contains(".") && !t.contains(":") {
                let chk = AllowInput.country(t, existing: e.config.allow.countries)
                guard let v = chk.value else { return .error(chk.error ?? "неверная страна") }
                kind = .country(v); warning = nil
            } else {
                let chk = AllowInput.ip(t, existing: e.config.allow.ips)
                guard let v = chk.value else { return .error(chk.error ?? "неверный IP") }
                kind = .ip(v); warning = chk.warning
            }
        } else {
            guard let c = e.status.confirmed else {
                return .error("Текущий IP не подтверждён (сервисы расходятся или нет сети): разрешать нечего. Укажите IP, подсеть или страну.")
            }
            if e.config.allow.ips.contains(where: { IPMatcher.matches(c.ip, entry: $0) }) {
                return IPCResponse(ok: true, text: "IP \(c.ip) уже разрешён")
            }
            kind = .ip(c.ip); warning = nil
        }
        let result: Engine.UpdateResult
        let what: String
        switch kind {
        case .ip(let ip):
            result = e.updateConfig { if !$0.allow.ips.contains(ip) { $0.allow.ips.append(ip) } }
            what = ip.contains("/") ? "Разрешена подсеть \(ip)" : "Разрешён IP \(ip)"
        case .country(let cc):
            result = e.updateConfig { if !$0.allow.countries.contains(cc) { $0.allow.countries.append(cc) } }
            what = "Разрешена страна \(cc)"
        }
        var extra = warning.map { "\nВнимание: \($0)" } ?? ""
        let own = AppCatalog.appIDs(in: e.config).filter { e.config.appRules[$0] != nil }
        if !own.isEmpty {
            extra += "\nОбщий список изменён. У приложений со своими правилами (\(own.map { AppCatalog.displayName(for: $0) }.joined(separator: ", "))) он не действует — их правила меняются в панели, вкладка «Приложения»."
        }
        switch result {
        case .invalid(let m): return .error(m)
        case .saved: return IPCResponse(ok: true, text: what + extra)
        case .unchanged: return .error("SafeNet завершает работу: ничего не изменено")
        case .refused(let m): return .error("\(m). Изменение не записано, действует до выхода из приложения.")
        case .notSaved(let m): return .error("\(m)")
        }
    }
}

// MARK: - Console client

/// `SafeNetApp <command>`: no AppKit, no UI. Exit codes: 0 ok, 1 error reported by the app, 2 usage,
/// 3 SafeNet is not running. `config` and `version` need no server.
public func runCLIClient(_ args: [String], environment: [String: String] = ProcessInfo.processInfo.environment,
                         out: (String) -> Void, err: (String) -> Void) -> Int32 {
    if args == ["help"] || args == ["--help"] || args == ["-h"] { out(cliUsage); return 0 }
    guard let cmd = parseCLI(args) else { err(cliUsage); return 2 }
    let paths = AppPaths.from(environment: environment)
    switch cmd {
    case .config: out(paths.config.path); return 0
    case .version: out("SafeNet \(AppState.version)"); return 0
    default: break
    }
    switch IPCClient.send(cmd, path: paths.socketPath, timeout: 2) {
    case .success(let r):
        (r.ok ? out : err)(r.text)
        return r.ok ? 0 : 1
    case .failure(.notRunning):
        err("SafeNet не запущен. Запустите приложение и повторите команду.")
        return 3
    case .failure(.timeout):
        err("SafeNet не отвечает (таймаут).")
        return 1
    case .failure(.protocolError(let m)):
        err("Ошибка связи с SafeNet: \(m)")
        return 1
    }
}

/// True when the first argument is meant for the console client rather than the app / watchdog:
/// a word (not an option such as `-psn_…` or `--watchdog`), or a help / version flag.
public func isCLIInvocation(_ args: [String]) -> Bool {
    guard let f = args.dropFirst().first else { return false }
    return !f.hasPrefix("-") || ["--help", "-h", "--version"].contains(f)
}
