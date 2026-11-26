import Foundation
import Darwin

// Self-updater, install part. Runs in a helper process (`SafeNetApp --install-update ...`, the
// CURRENT binary, started by the app right before it quits), so the bundle is swapped only after
// the old app has exited and resumed every frozen process:
//   1. wait for the app to exit (max `parentTimeout`; otherwise give up, nothing touched);
//   2. re-validate the staged bundle (identifier, version, code signature);
//   3. copy it next to the installed app, then two renames: installed -> .old, new -> installed
//      (a failed second rename puts the old one back);
//   4. write the "pending" marker and launch the new app; it removes the marker once it runs;
//   5. no confirmation within `confirmTimeout` -> stop the new instance, restore the old bundle,
//      start it again. The outcome is written to the "result" marker, shown by the next start.

/// Files next to config.yaml that pass the update outcome between the helper and the app.
public struct UpdateMarkers {
    public let dir: URL
    public init(dir: URL) { self.dir = dir }
    public var pending: URL { dir.appendingPathComponent("update-pending.json") }
    public var result: URL { dir.appendingPathComponent("update-result.json") }
    /// Where downloads are unpacked (`<dir>/updates/<version>/`).
    public var staging: URL { dir.appendingPathComponent("updates", isDirectory: true) }

    public struct Pending: Codable, Equatable { public var version: String; public var pid: Int32 }
    public struct Result: Codable, Equatable {
        public var ok: Bool
        public var from: String
        public var to: String
        public var message: String
        public init(ok: Bool, from: String, to: String, message: String) {
            self.ok = ok; self.from = from; self.to = to; self.message = message
        }
    }

    func write<T: Encodable>(_ v: T, to url: URL) {
        guard let d = try? JSONEncoder().encode(v) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }

    func read<T: Decodable>(_ t: T.Type, _ url: URL) -> T? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(t, from: d)
    }

    /// Called by the app once it runs: confirms a pending install of THIS version (the helper is
    /// waiting for exactly that). Returns true when a pending marker was confirmed.
    @discardableResult
    public func confirmLaunch(version: String) -> Bool {
        guard let p = read(Pending.self, pending), p.version == version else { return false }
        try? FileManager.default.removeItem(at: pending)
        return true
    }

    /// The outcome of the last install for the version now running, removed once read (shown
    /// once). A success counts only when this IS the new version, a failure only when this is the
    /// version that stayed; anything else is a leftover of another install and is dropped silently.
    public func takeResult(currentVersion: String) -> Result? {
        guard let r = read(Result.self, result) else { return nil }
        try? FileManager.default.removeItem(at: result)
        return (r.ok ? r.to : r.from) == currentVersion ? r : nil
    }
}

/// Everything the installer does to the system, so tests run it against temp directories.
public protocol InstallerSystem {
    /// Blocks until `pid` has exited; false when it is still alive after `timeout`.
    func waitForExit(_ pid: Int32, timeout: TimeInterval) -> Bool
    /// nil = acceptable; otherwise why the bundle must not be installed.
    func validate(app: URL, bundleID: String, version: String) -> String?
    func copy(_ from: URL, to: URL) throws
    func rename(_ from: URL, to: URL) throws
    func remove(_ url: URL)
    func exists(_ url: URL) -> Bool
    func clearAttributes(_ url: URL)
    func launch(_ app: URL) -> Bool
    /// Stops processes running the executable of this bundle (a new instance that hung).
    func stopInstances(of app: URL)
    func sleep(_ seconds: TimeInterval)
    var now: Date { get }
}

public struct UpdateInstaller {
    public struct Plan: Equatable {
        public var parentPID: Int32
        public var staged: URL
        public var target: URL
        public var stateDir: URL
        public var bundleID: String
        public var fromVersion: String
        public var toVersion: String
        public init(parentPID: Int32, staged: URL, target: URL, stateDir: URL, bundleID: String,
                    fromVersion: String, toVersion: String) {
            self.parentPID = parentPID; self.staged = staged; self.target = target; self.stateDir = stateDir
            self.bundleID = bundleID; self.fromVersion = fromVersion; self.toVersion = toVersion
        }

        /// argv after `--install-update`.
        public var arguments: [String] {
            ["\(parentPID)", staged.path, target.path, stateDir.path, bundleID, fromVersion, toVersion]
        }

        /// Strict: both paths absolute `.app` bundles, the target a direct child of its folder,
        /// versions parse, pid > 1.
        public init?(arguments a: [String]) {
            guard a.count == 7, let pid = Int32(a[0]), pid > 1,
                  a[1].hasPrefix("/"), a[1].hasSuffix(".app"), a[2].hasPrefix("/"), a[2].hasSuffix(".app"),
                  a[3].hasPrefix("/"), !a[4].isEmpty, AppVersion(a[5]) != nil, AppVersion(a[6]) != nil,
                  !a[1].contains("/../"), !a[2].contains("/../") else { return nil }
            self.init(parentPID: pid, staged: URL(fileURLWithPath: a[1]), target: URL(fileURLWithPath: a[2]),
                      stateDir: URL(fileURLWithPath: a[3], isDirectory: true), bundleID: a[4],
                      fromVersion: a[5], toVersion: a[6])
        }
    }

    public enum Outcome: Equatable {
        case installed
        /// Nothing was changed (app did not exit, bundle invalid, copy failed).
        case aborted(String)
        /// The new version was installed but did not start; the old one is back.
        case rolledBack(String)
    }

    let system: InstallerSystem
    var parentTimeout: TimeInterval = 60
    /// The new instance may wait up to `InstanceLock.appWait` (20 s) for the old watchdog.
    var confirmTimeout: TimeInterval = 45
    var pollInterval: TimeInterval = 0.25

    public init(system: InstallerSystem) { self.system = system }

    @discardableResult
    public func run(_ plan: Plan) -> Outcome {
        let markers = UpdateMarkers(dir: plan.stateDir)
        let (outcome, relaunch) = install(plan, markers)
        // The outcome is written BEFORE any version is started: the app reads it once, right at
        // launch. A successful install already wrote it before starting the new version (that
        // version consumed it), so it is not written a second time.
        if outcome != .installed { markers.write(UpdateInstaller.result(outcome, plan), to: markers.result) }
        if relaunch, system.exists(plan.target) { _ = system.launch(plan.target) }
        // The staged copy (`<stateDir>/updates/<version>/SafeNet.app`) is no longer needed either
        // way (a later check downloads again). Only ever removed inside the staging folder.
        let versionDir = plan.staged.deletingLastPathComponent().standardizedFileURL
        if versionDir.path.hasPrefix(markers.staging.standardizedFileURL.path + "/") { system.remove(versionDir) }
        return outcome
    }

    static func result(_ outcome: Outcome, _ plan: Plan) -> UpdateMarkers.Result {
        switch outcome {
        case .installed:
            return .init(ok: true, from: plan.fromVersion, to: plan.toVersion, message: "SafeNet обновлён до \(plan.toVersion)")
        case .aborted(let m):
            return .init(ok: false, from: plan.fromVersion, to: plan.toVersion, message: "Обновление до \(plan.toVersion) не установлено: \(m)")
        case .rolledBack(let m):
            return .init(ok: false, from: plan.fromVersion, to: plan.toVersion,
                         message: "Версия \(plan.toVersion) не запустилась (\(m)), возвращена версия \(plan.fromVersion)")
        }
    }

    /// Returns the outcome and whether the installed (old) app must be started again by `run`.
    private func install(_ plan: Plan, _ markers: UpdateMarkers) -> (Outcome, Bool) {
        guard system.waitForExit(plan.parentPID, timeout: parentTimeout) else {
            // The app is still running: restarting it from under it is not safe. Nothing touched.
            return (.aborted("SafeNet не завершился"), false)
        }
        if let why = system.validate(app: plan.staged, bundleID: plan.bundleID, version: plan.toVersion) {
            return (.aborted(why), true)
        }
        let folder = plan.target.deletingLastPathComponent()
        let tag = "\(getpid())"
        let fresh = folder.appendingPathComponent(".\(plan.target.lastPathComponent).new-\(tag)")
        let old = folder.appendingPathComponent(".\(plan.target.lastPathComponent).old-\(tag)")
        system.remove(fresh)
        do { try system.copy(plan.staged, to: fresh) } catch {
            system.remove(fresh)
            return (.aborted("нет прав на запись в \(folder.lastPathComponent)"), true)
        }
        system.clearAttributes(fresh)
        let hadOld = system.exists(plan.target)
        if hadOld {
            do { try system.rename(plan.target, to: old) } catch {
                system.remove(fresh)
                return (.aborted("не удалось убрать прежнюю версию"), true)
            }
        }
        do { try system.rename(fresh, to: plan.target) } catch {
            if hadOld { try? system.rename(old, to: plan.target) }
            system.remove(fresh)
            return (.aborted("не удалось поставить новую версию"), true)
        }

        markers.write(UpdateMarkers.Pending(version: plan.toVersion, pid: getpid()), to: markers.pending)
        // Provisional success, read by the new version as it starts; a rollback overwrites it.
        markers.write(UpdateInstaller.result(.installed, plan), to: markers.result)
        guard system.launch(plan.target) else {
            return rollBack(plan, old: hadOld ? old : nil, markers, "запуск не удался")
        }
        let deadline = system.now.addingTimeInterval(confirmTimeout)
        while system.exists(markers.pending) {
            if system.now >= deadline { return rollBack(plan, old: hadOld ? old : nil, markers, "нет ответа") }
            system.sleep(pollInterval)
        }
        if hadOld { system.remove(old) }
        return (.installed, false)
    }

    private func rollBack(_ plan: Plan, old: URL?, _ markers: UpdateMarkers, _ why: String) -> (Outcome, Bool) {
        system.remove(markers.pending)
        guard let old = old else { return (.rolledBack(why + "; прежней версии не было"), false) }
        system.stopInstances(of: plan.target)
        let failed = plan.target.deletingLastPathComponent()
            .appendingPathComponent(".\(plan.target.lastPathComponent).failed-\(getpid())")
        do {
            try system.rename(plan.target, to: failed)
            try system.rename(old, to: plan.target)
        } catch {
            return (.rolledBack(why + "; прежнюю версию вернуть не удалось"), false)
        }
        system.remove(failed)
        return (.rolledBack(why), true)
    }

    // MARK: Entry point of the helper process

    /// `SafeNetApp --install-update <args>`: returns the process exit code.
    public static func runHelper(arguments: [String]) -> Int32 {
        guard let plan = Plan(arguments: arguments) else {
            FileHandle.standardError.write(Data("usage: SafeNetApp --install-update <pid> <staged.app> <target.app> <stateDir> <bundleID> <from> <to>\n".utf8))
            return 2
        }
        let outcome = UpdateInstaller(system: RealInstallerSystem()).run(plan)
        NSLog("SafeNet updater: %@", "\(outcome)")
        return outcome == .installed ? 0 : 1
    }
}

// MARK: - Real system

public struct RealInstallerSystem: InstallerSystem {
    public init() {}

    public func waitForExit(_ pid: Int32, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            usleep(100_000)
        }
        return kill(pid, 0) != 0 && errno == ESRCH
    }

    public func validate(app: URL, bundleID: String, version: String) -> String? {
        Self.validateBundle(app, bundleID: bundleID, version: version, runner: ProcessCommandRunner())
    }

    /// Identifier and version from Info.plist, the executable present, and a valid code signature
    /// (`codesign --verify --deep --strict`): a damaged or foreign bundle is never installed.
    public static func validateBundle(_ app: URL, bundleID: String, version: String, runner: CommandRunner) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) as? [String: Any] else { return "нет Info.plist" }
        guard info["CFBundleIdentifier"] as? String == bundleID else { return "другое приложение" }
        guard let v = info["CFBundleShortVersionString"] as? String, v == version else { return "версия не совпадает с описанием" }
        guard let exe = info["CFBundleExecutable"] as? String, !exe.contains("/"),
              FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/\(exe)").path) else {
            return "нет исполняемого файла"
        }
        guard runner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], timeout: 60) != nil else {
            return "подпись приложения не проходит проверку"
        }
        return nil
    }

    public func copy(_ from: URL, to: URL) throws {
        // ditto keeps the bundle exactly (symlinks, permissions, the signature seal).
        guard ProcessCommandRunner().run("/usr/bin/ditto", [from.path, to.path], timeout: 120) != nil else {
            throw UpdateError.install("ditto")
        }
    }

    public func rename(_ from: URL, to: URL) throws {
        guard Darwin.rename(from.path, to.path) == 0 else { throw UpdateError.install("rename \(errno)") }
    }

    public func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    public func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    public func clearAttributes(_ url: URL) {
        _ = ProcessCommandRunner().run("/usr/bin/xattr", ["-cr", url.path], timeout: 30)
    }

    public func launch(_ app: URL) -> Bool {
        ProcessCommandRunner().run("/usr/bin/open", [app.path], timeout: 30) != nil
    }

    public func stopInstances(of app: URL) {
        let exe = app.appendingPathComponent("Contents/MacOS").path + "/"
        let me = getpid(), uid = getuid()
        let victims = SystemProcessTable().list().filter { $0.path.hasPrefix(exe) && $0.pid != me && $0.pid > 1 && $0.uid == uid }
        for p in victims { _ = kill(p.pid, SIGTERM) }
        for _ in 0..<50 where victims.contains(where: { kill($0.pid, 0) == 0 }) { usleep(100_000) }
        for p in victims where kill(p.pid, 0) == 0 { _ = kill(p.pid, SIGKILL) }
    }

    public func sleep(_ seconds: TimeInterval) { usleep(useconds_t(max(0, seconds) * 1_000_000)) }

    public var now: Date { Date() }
}
