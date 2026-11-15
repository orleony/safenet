import Foundation

/// Reads/writes config.yaml and watches it for external edits.
///
/// - `load()`: missing file => `Config.default` (file is NOT created). Malformed file => throws.
/// - `save(_:)`: atomic (temp file + rename), creates the parent directory. The file always stays
///   valid YAML. Comment preservation is best-effort: full-line comments that sit directly above a
///   map key (not inside lists) are re-attached to that key by path; trailing `# ...` comments and
///   comments inside lists are dropped. Own saves do not trigger the watch callback.
/// - `watch(queue:onChange:)`: reports `.success(Config)` or `.failure(error)` whenever file content
///   changes (DispatchSource on the file and its directory, plus a 1 s poll as safety net, which
///   also covers atomic-replace editors). Callers keep their previous Config on `.failure`.
///   A deleted file is ignored. The same broken content is reported once.
public final class ConfigStore {
    public let url: URL
    private let lock = NSLock()
    private let work = DispatchQueue(label: "safenet.configstore")
    private var lastData: Data?
    private var fileSource: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var callback: ((Result<Config, Error>) -> Void)?
    private var callbackQueue: DispatchQueue = .main
    private var watching = false

    public init(url: URL) { self.url = url }

    deinit { stopWatching() }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SafeNet/config.yaml")
    }

    public func load() throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return .default }
        let data = try Data(contentsOf: url)
        return try Self.decode(data)
    }

    static func decode(_ data: Data) throws -> Config {
        guard let text = String(data: data, encoding: .utf8) else { throw ConfigError("file is not valid UTF-8") }
        return try Config(yaml: try MiniYAML.parse(text))
    }

    public func save(_ c: Config) throws {
        var comments: [String: [String]] = [:]
        if let old = try? String(contentsOf: url, encoding: .utf8) { comments = MiniYAML.extractComments(old) }
        let text = MiniYAML.emit(c.toYAML(), comments: comments)
        let data = Data(text.utf8)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        lock.lock(); lastData = data; lock.unlock()   // do not echo our own save to the watcher
    }

    public func watch(queue: DispatchQueue = .main, onChange: @escaping (Result<Config, Error>) -> Void) {
        stopWatching()
        lock.lock()
        callback = onChange
        callbackQueue = queue
        lastData = try? Data(contentsOf: url)
        watching = true
        lock.unlock()
        work.async { [weak self] in
            guard let self = self else { return }
            self.openSources()
            let t = DispatchSource.makeTimerSource(queue: self.work)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { [weak self] in self?.check() }
            self.lock.lock(); self.timer = t; self.lock.unlock()
            t.resume()
        }
    }

    public func stopWatching() {
        lock.lock()
        watching = false
        callback = nil
        let f = fileSource, d = dirSource, t = timer
        fileSource = nil; dirSource = nil; timer = nil
        lock.unlock()
        f?.cancel(); d?.cancel(); t?.cancel()
    }

    // Runs on `work`.
    private func openSources() {
        lock.lock(); let on = watching; lock.unlock()
        guard on else { return }
        fileSource?.cancel(); dirSource?.cancel()
        fileSource = makeSource(path: url.path, mask: [.write, .extend, .delete, .rename, .attrib])
        dirSource = makeSource(path: url.deletingLastPathComponent().path, mask: [.write, .rename, .delete])
    }

    private func makeSource(path: String, mask: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: work)
        s.setEventHandler { [weak self] in
            guard let self = self else { return }
            let ev = s.data
            if ev.contains(.delete) || ev.contains(.rename) { self.openSources() }  // file replaced: re-attach
            self.work.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.check() } // debounce
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        return s
    }

    // Runs on `work`.
    private func check() {
        lock.lock()
        guard watching, let cb = callback else { lock.unlock(); return }
        let q = callbackQueue
        let previous = lastData
        lock.unlock()
        guard let data = try? Data(contentsOf: url) else { return }   // missing/unreadable: ignore
        if data == previous { return }
        lock.lock(); lastData = data; lock.unlock()
        let result: Result<Config, Error>
        do { result = .success(try Self.decode(data)) } catch { result = .failure(error) }
        q.async { cb(result) }
    }
}
