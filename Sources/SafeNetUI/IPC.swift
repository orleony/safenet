import Foundation
import Darwin
import SafeNetCore

// CLI <-> running app over a unix-domain stream socket (`AppPaths.socketPath`).
//
// Protocol (SafeNetCore/IPC/Protocol.swift): one request line, one response line, then the server
// closes. Security: the socket is 0600 inside a 0700 directory, the peer must be the same uid
// (getpeereid), reads have a deadline and a size cap, the number of concurrent connections is
// capped, a stale socket is removed only when nobody answers on it.

public enum IPCServerError: Error, Equatable, CustomStringConvertible {
    case alreadyRunning
    case badDirectory(String)
    case system(String, Int32)
    public var description: String {
        switch self {
        case .alreadyRunning: return "SafeNet уже запущен (сокет занят)"
        case .badDirectory(let m): return "каталог сокета: \(m)"
        case .system(let w, let e): return "\(w): \(String(cString: strerror(e)))"
        }
    }
}

/// A peer that closes early must never kill the process: writes then fail with EPIPE (handled),
/// not SIGPIPE. `SO_NOSIGPIPE` alone is not enough: on macOS it fails with EINVAL on a socket whose
/// peer is already gone. Idempotent; called by the server, the client and `main`.
func ignoreSIGPIPE() { signal(SIGPIPE, SIG_IGN) }

public final class IPCServer {
    public typealias Handler = (CLICommand, @escaping (IPCResponse) -> Void) -> Void

    public let path: String
    private let handler: Handler
    private let peerAllowed: (Int32) -> Bool
    private let readTimeout: TimeInterval
    private let replyTimeout: TimeInterval
    private let maxConnections: Int
    private let strictDirectory: Bool
    private let queue = DispatchQueue(label: "safenet.ipc.accept")
    private let lock = NSLock()
    private var active = 0
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var inode: ino_t = 0

    /// - strictDirectory: the directory must not be a symlink (the temp-dir fallback).
    /// - peerAllowed: gets the accepted connection's fd; default = same uid as this process.
    public init(path: String, readTimeout: TimeInterval = 2, replyTimeout: TimeInterval = 5, maxConnections: Int = 16, strictDirectory: Bool = false,
                peerAllowed: @escaping (Int32) -> Bool = { IPCServer.peerIsSameUser($0) },
                handler: @escaping Handler) {
        self.path = path; self.readTimeout = readTimeout; self.replyTimeout = replyTimeout
        self.maxConnections = maxConnections; self.strictDirectory = strictDirectory; self.peerAllowed = peerAllowed; self.handler = handler
    }

    deinit { stop() }

    /// Same uid as ours (`getpeereid`); false when the credentials cannot be read.
    public static func peerIsSameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return false }
        return peerUIDAllowed(uid, me: getuid())
    }

    /// The decision itself, separate so tests can exercise a "wrong uid".
    public static func peerUIDAllowed(_ uid: uid_t, me: uid_t) -> Bool { uid == me }

    // MARK: Start / stop

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard listenFD < 0 else { return }
        ignoreSIGPIPE()
        let dir = (path as NSString).deletingLastPathComponent
        try IPCServer.prepareDirectory(dir, strict: strictDirectory)
        try IPCServer.removeStaleSocket(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCServerError.system("socket", errno) }
        var addr = sockaddr_un()
        guard IPCServer.fill(&addr, path: path) else { close(fd); throw IPCServerError.badDirectory("путь слишком длинный") }
        let old = umask(0o177)                                   // the socket file is created 0600
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        let bindErr = errno
        umask(old)
        guard rc == 0 else { close(fd); throw IPCServerError.system("bind", bindErr) }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { let e = errno; close(fd); unlink(path); throw IPCServerError.system("listen", e) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var st = stat()
        if lstat(path, &st) == 0 { inode = st.st_ino }
        listenFD = fd

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptPending(fd) }
        src.setCancelHandler { close(fd) }                       // closed only once no handler can run on it
        src.resume()
        source = src
    }

    /// Closes the listening socket and removes the socket file (only if it is still ours).
    public func stop() {
        lock.lock()
        let fd = listenFD, src = source, ino = inode
        listenFD = -1; source = nil
        lock.unlock()
        guard fd >= 0 else { return }
        src?.cancel()
        var st = stat()
        if lstat(path, &st) == 0, st.st_ino == ino, (st.st_mode & S_IFMT) == S_IFSOCK { unlink(path) }
    }

    /// Creates the directory 0700 (parents with default rights) and checks it: ours, a directory
    /// (strict: not a symlink). Existing directories are tightened to 0700.
    static func prepareDirectory(_ dir: String, strict: Bool) throws {
        var st = stat()
        if lstat(dir, &st) != 0 {
            do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700]) }
            catch { throw IPCServerError.badDirectory("не создать каталог") }
            guard lstat(dir, &st) == 0 else { throw IPCServerError.badDirectory("не создать каталог") }
        }
        if (st.st_mode & S_IFMT) == S_IFLNK {
            if strict { throw IPCServerError.badDirectory("символическая ссылка") }
            guard stat(dir, &st) == 0 else { throw IPCServerError.badDirectory("не прочитать каталог") }
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw IPCServerError.badDirectory("не каталог") }
        guard st.st_uid == getuid() else { throw IPCServerError.badDirectory("каталог принадлежит другому пользователю") }
        if (st.st_mode & 0o777) != 0o700 { guard chmod(dir, 0o700) == 0 else { throw IPCServerError.badDirectory("нет прав на каталог") } }
    }

    /// A leftover socket file is removed only when it is a socket of ours and nothing answers on it.
    static func removeStaleSocket(_ path: String) throws {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        guard (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() else {
            throw IPCServerError.badDirectory("на месте сокета лежит посторонний файл")
        }
        switch IPCClient.connect(path: path, timeout: 1) {
        case .success(let fd): close(fd); throw IPCServerError.alreadyRunning
        case .failure(let e):
            if e == .timeout { throw IPCServerError.alreadyRunning }       // busy = alive
            unlink(path)
        }
    }

    static func fill(_ addr: inout sockaddr_un, path: String) -> Bool {
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard !bytes.isEmpty, bytes.count < cap else { return false }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        return true
    }

    // MARK: Connections

    private func acceptPending(_ lfd: Int32) {
        while true {
            let c = accept(lfd, nil, nil)
            if c < 0 { return }                                   // EAGAIN: drained
            var one: Int32 = 1
            // May fail (EINVAL) when the peer is already gone: non-fatal, SIGPIPE is ignored
            // process-wide and every write checks its result.
            _ = setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(c, F_SETFD, FD_CLOEXEC)
            guard peerAllowed(c) else { close(c); continue }
            lock.lock()
            let ok = active < maxConnections
            if ok { active += 1 }
            lock.unlock()
            guard ok else {
                // Over the cap: a short "busy" answer. The request is read first (briefly): closing
                // a socket with unread data resets the connection and the client would lose the answer.
                DispatchQueue.global(qos: .utility).async {
                    _ = IPCIO.readLine(c, timeout: 0.3)
                    _ = IPCIO.write(c, encodeMessage(IPCResponse.error("SafeNet занят, повторите команду")), timeout: 0.2)
                    shutdown(c, SHUT_WR); close(c)
                }
                continue
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.serve(c) }
        }
    }

    private func release() { lock.lock(); active -= 1; lock.unlock() }

    private func serve(_ fd: Int32) {
        let line = IPCIO.readLine(fd, timeout: readTimeout)
        let command: CLICommand
        switch line {
        case .failure(.timeout), .failure(.closed):               // slow or vanished client: just drop it
            close(fd); release(); return
        case .failure(.tooLarge):
            return reply(fd, .error(IPCDecodeError.tooLarge.description))
        case .success(let data):
            do { command = try decodeRequest(data) } catch {
                return reply(fd, .error((error as? IPCDecodeError)?.description ?? "ошибка запроса"))
            }
        }
        let once = Once()
        // The reply is written off the caller's queue (the engine queue): a client that stops
        // reading must never stall the engine.
        handler(command) { [weak self] r in
            DispatchQueue.global(qos: .utility).async { once.run { self?.reply(fd, r) } }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + replyTimeout) { [weak self] in
            once.run { self?.reply(fd, .error("SafeNet не ответил вовремя")) }
        }
    }

    private func reply(_ fd: Int32, _ r: IPCResponse) {
        var r = r
        if r.text.utf8.count > ipcMaxMessage / 2 { r.text = String(r.text.prefix(ipcMaxMessage / 4)) + "…" }
        _ = IPCIO.write(fd, encodeMessage(r), timeout: 2)
        shutdown(fd, SHUT_WR)
        close(fd)
        release()
    }

    private final class Once {
        private let l = NSLock(); private var done = false
        func run(_ f: () -> Void) {
            l.lock(); let first = !done; done = true; l.unlock()
            if first { f() }
        }
    }
}

enum IPCIO {
    enum ReadError: Error { case timeout, closed, tooLarge }

    /// Reads up to and including the first newline. Deadline is for the whole message.
    static func readLine(_ fd: Int32, timeout: TimeInterval) -> Result<Data, ReadError> {
        let end = Date().addingTimeInterval(timeout)
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let left = end.timeIntervalSinceNow
            if left <= 0 { return .failure(.timeout) }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&p, 1, Int32(min(left * 1000, 60_000).rounded(.up)))
            if pr < 0 { if errno == EINTR { continue }; return .failure(.closed) }
            if pr == 0 { return .failure(.timeout) }
            let n = read(fd, &buf, buf.count)
            if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return .failure(.closed) }
            if n == 0 { return out.isEmpty ? .failure(.closed) : .success(out) }   // EOF without newline
            if let nl = buf[0..<n].firstIndex(of: 0x0A) {
                out.append(contentsOf: buf[0...nl])
                return out.count > ipcMaxMessage ? .failure(.tooLarge) : .success(out)
            }
            out.append(contentsOf: buf[0..<n])
            if out.count > ipcMaxMessage { return .failure(.tooLarge) }
        }
    }

    static func write(_ fd: Int32, _ data: Data, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        var off = 0
        let bytes = [UInt8](data)
        while off < bytes.count {
            let left = end.timeIntervalSinceNow
            if left <= 0 { return false }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let pr = poll(&p, 1, Int32(min(left * 1000, 60_000).rounded(.up)))
            if pr < 0 { if errno == EINTR { continue }; return false }
            if pr == 0 { return false }
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + off, bytes.count - off) }
            if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return false }
            off += n
        }
        return true
    }
}

// MARK: - Client

public enum IPCClientError: Error, Equatable {
    /// No socket, or nobody listens on it.
    case notRunning
    case timeout
    case protocolError(String)
}

public enum IPCClient {
    /// Connected fd (blocking, send/receive timeouts set).
    static func connect(path: String, timeout: TimeInterval) -> Result<Int32, IPCClientError> {
        ignoreSIGPIPE()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.protocolError("socket")) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var addr = sockaddr_un()
        guard IPCServer.fill(&addr, path: path) else { close(fd); return .failure(.notRunning) }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if rc != 0 {
            let e = errno
            close(fd)
            // A full accept backlog answers EAGAIN: somebody is listening, just busy.
            if e == EAGAIN || e == EINPROGRESS { return .failure(.timeout) }
            return .failure(.notRunning)                          // ENOENT, ECONNREFUSED, ENOTSOCK, EACCES ...
        }
        _ = fcntl(fd, F_SETFL, flags)
        return .success(fd)
    }

    public static func send(_ c: CLICommand, path: String, timeout: TimeInterval = 2) -> Result<IPCResponse, IPCClientError> {
        exchange(encodeMessage(IPCRequest(c)), path: path, timeout: timeout).flatMap { data in
            do { return .success(try decodeResponse(data)) } catch { return .failure(.protocolError("непонятный ответ")) }
        }
    }

    /// Raw round trip (tests send garbage through it): returns the response line.
    static func exchange(_ request: Data, path: String, timeout: TimeInterval, shutdownWrite: Bool = false) -> Result<Data, IPCClientError> {
        let fd: Int32
        switch connect(path: path, timeout: timeout) {
        case .success(let f): fd = f
        case .failure(let e): return .failure(e)
        }
        defer { close(fd) }
        guard IPCIO.write(fd, request, timeout: timeout) else { return .failure(.timeout) }
        if shutdownWrite { shutdown(fd, SHUT_WR) }
        switch IPCIO.readLine(fd, timeout: timeout + 5) {
        case .success(let d): return .success(d)
        case .failure(.timeout): return .failure(.timeout)
        case .failure(.closed): return .failure(.protocolError("соединение закрыто без ответа"))
        case .failure(.tooLarge): return .failure(.protocolError("ответ слишком большой"))
        }
    }
}
