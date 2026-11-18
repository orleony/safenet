import Foundation
import Darwin

/// One running process as seen at the moment of listing.
/// `startTime` + `pid` identify a process; a pid alone may be reused after exit.
public struct ProcInfo: Equatable {
    public var pid: Int32
    public var ppid: Int32
    /// Kernel process name (p_comm: truncated to 16 characters, MAXCOMLEN).
    public var name: String
    /// Full executable path, "" when unknown.
    public var path: String
    /// Command line (argv joined by spaces), "" when unknown.
    public var args: String
    public var startTime: Date
    /// Effective uid.
    public var uid: uid_t

    public init(pid: Int32, ppid: Int32 = 0, name: String, path: String, args: String = "",
                startTime: Date, uid: uid_t) {
        self.pid = pid; self.ppid = ppid; self.name = name; self.path = path
        self.args = args; self.startTime = startTime; self.uid = uid
    }

    /// Basename of the executable (falls back to the kernel name when the path is unknown).
    public var executableName: String {
        path.isEmpty ? name : (path as NSString).lastPathComponent
    }

    /// Outermost `.app` bundle containing the executable, e.g. "/Applications/Claude.app".
    public var bundleRoot: String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[path.startIndex..<path.index(r.lowerBound, offsetBy: 4)])
    }
}

public protocol ProcessTable {
    func list() -> [ProcInfo]
    /// Like `list()`, but nil when the listing failed (unknown state, as opposed to "no processes").
    func snapshot() -> [ProcInfo]?
}

extension ProcessTable {
    public func snapshot() -> [ProcInfo]? { list() }
}

// MARK: - Never-freeze list

/// Executable / kernel names that are never frozen (compared case-insensitively).
public let neverFreezeNames: Set<String> = ["launchd", "windowserver", "finder", "dock", "loginwindow",
                                             "safenet", "safenetapp", "kernel_task"]
/// Path prefixes that are never frozen (compared case-insensitively).
public let neverFreezePathPrefixes: [String] = ["/system/", "/usr/libexec/", "/sbin/", "/usr/sbin/"]

/// True when SafeNet must never signal this process: SafeNet itself, pid <= 1, other users'
/// and root processes, unknown executable path, deny-listed names and system paths.
public func isProtected(_ p: ProcInfo, selfPID: Int32, myUID: uid_t) -> Bool {
    if p.pid <= 1 || p.pid == selfPID { return true }
    if p.uid != myUID || p.uid == 0 { return true }
    if p.path.isEmpty { return true }        // cannot prove it is not a system process
    if neverFreezeNames.contains(p.name.lowercased()) || neverFreezeNames.contains(p.executableName.lowercased()) {
        return true
    }
    let lp = p.path.lowercased()
    return neverFreezePathPrefixes.contains { lp.hasPrefix($0) }
}

// MARK: - Matching

/// Matches processes against a `CustomApp.match` string:
/// - `args:<fragment>`: the command line contains the fragment (case-sensitive);
/// - `cmd:<name>`: the basename of argv[0] or argv[1] equals the name (case-sensitive), e.g.
///   `cmd:claude` for `node /usr/local/bin/claude` or a node process titled `claude`;
/// - a string containing "/": the executable path contains it (case-insensitive);
/// - otherwise: the process / executable name equals it (case-insensitive);
/// - `A && B && …`: every part must match (e.g. `node && cmd:claude`: a node process running claude,
///   never an editor or `npm i` that merely mentions it).
/// An empty, whitespace-only, bare "args:"/"cmd:" or slashes-only string (or part) never matches anything.
public struct AppMatcher: Equatable {
    public indirect enum Kind: Equatable { case name(String), path(String), args(String), cmd(String), all([Kind]), never }
    public let kind: Kind

    public init(match: String) {
        let parts = match.components(separatedBy: "&&")
        if parts.count > 1 {
            let kinds = parts.map(AppMatcher.single)
            kind = kinds.contains(.never) ? .never : .all(kinds)
        } else {
            kind = AppMatcher.single(match)
        }
    }

    static func single(_ match: String) -> Kind {
        let t = match.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        if lower.hasPrefix("args:") {
            let frag = String(t.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            return frag.isEmpty ? .never : .args(frag)
        }
        if lower.hasPrefix("cmd:") {
            let n = String(t.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            return n.isEmpty || n.contains("/") ? .never : .cmd(n)
        }
        if t.contains("/") {
            return t.allSatisfy({ $0 == "/" || $0.isWhitespace }) ? .never : .path(t)
        }
        return t.isEmpty ? .never : .name(t)
    }

    public init(_ app: CustomApp) { self.init(match: app.match) }

    public func matches(_ p: ProcInfo) -> Bool { AppMatcher.matches(kind, p) }

    private static func matches(_ kind: Kind, _ p: ProcInfo) -> Bool {
        switch kind {
        case .never: return false
        case .name(let n):
            return p.name.caseInsensitiveCompare(n) == .orderedSame
                || (!p.path.isEmpty && p.executableName.caseInsensitiveCompare(n) == .orderedSame)
        case .path(let frag):
            return !p.path.isEmpty && p.path.range(of: frag, options: .caseInsensitive) != nil
        case .args(let frag):
            return p.args.contains(frag)
        case .cmd(let n):
            let words = p.args.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).prefix(2)
            return words.contains { ($0.split(separator: "/").last.map(String.init) ?? "") == n }
        case .all(let parts):
            return !parts.isEmpty && parts.allSatisfy { matches($0, p) }
        }
    }

    /// Matching processes plus helpers living in the same `.app` bundle (for name/path rules;
    /// an `args:` rule selects only the matching processes, since interpreters such as
    /// Python.app are shared by unrelated scripts). Descendants are added by `Freezer`.
    /// The result is not filtered by `isProtected`; `Freezer` does that.
    public func select(from all: [ProcInfo]) -> [ProcInfo] {
        let direct = all.filter(matches)
        guard !direct.isEmpty else { return [] }
        var picked = Dictionary(direct.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        if kind.expandsToBundle {
            let roots = Set(direct.compactMap { $0.bundleRoot }).map { $0.lowercased() + "/" }
            if !roots.isEmpty {
                for p in all where picked[p.pid] == nil {
                    let lp = p.path.lowercased()
                    if roots.contains(where: { lp.hasPrefix($0) }) { picked[p.pid] = p }
                }
            }
        }
        return picked.values.sorted { $0.pid < $1.pid }
    }
}

// MARK: - System implementation (sysctl + libproc, public APIs only)

/// Lists processes with `sysctl(KERN_PROC_ALL)`; executable path via libproc `proc_pidpath`
/// (resolved with dlsym because libproc.h is not part of the Darwin Swift module on the
/// Command Line Tools SDK), falling back to the exec path from `KERN_PROCARGS2`; command line
/// from `KERN_PROCARGS2`. Unreadable fields (other users' processes) are left empty.
public struct SystemProcessTable: ProcessTable {
    public init() {}

    public func list() -> [ProcInfo] { snapshot() ?? [] }

    public func snapshot() -> [ProcInfo]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        let stride = MemoryLayout<kinfo_proc>.stride
        var kps: [kinfo_proc] = []
        var count = 0
        for _ in 0..<5 {                       // the table can grow between the two calls
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            kps = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 64)
            size = kps.count * stride
            if sysctl(&mib, 3, &kps, &size, nil, 0) == 0 { count = size / stride; break }
            if errno != ENOMEM { return nil }
        }
        guard count > 0 else { return nil }
        var argBuf = [UInt8](repeating: 0, count: SystemProcessTable.argMax())
        var out: [ProcInfo] = []
        out.reserveCapacity(count)
        for k in kps.prefix(count) {
            let pid = k.kp_proc.p_pid
            guard pid > 0, k.kp_proc.p_stat != 5 /* SZOMB */ else { continue }
            out.append(SystemProcessTable.make(k, argBuf: &argBuf))
        }
        return out
    }

    /// Info for one pid, or nil when it is gone or a zombie.
    public func info(pid: Int32) -> ProcInfo? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var k = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &k, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.stride,
              k.kp_proc.p_pid == pid, k.kp_proc.p_stat != 5 else { return nil }
        var buf = [UInt8](repeating: 0, count: SystemProcessTable.argMax())
        return SystemProcessTable.make(k, argBuf: &buf)
    }

    static func make(_ k: kinfo_proc, argBuf: inout [UInt8]) -> ProcInfo {
        var k = k
        let pid = k.kp_proc.p_pid
        let (execPath, args) = arguments(pid, buf: &argBuf)
        var path = pidPath(pid)
        if path.isEmpty, execPath.hasPrefix("/") { path = execPath }
        let st = k.kp_proc.p_un.__p_starttime
        let start = Double(st.tv_sec) + Double(st.tv_usec) / 1_000_000
        return ProcInfo(pid: pid, ppid: k.kp_eproc.e_ppid, name: cString(&k.kp_proc.p_comm), path: path,
                        args: args, startTime: Date(timeIntervalSince1970: start), uid: k.kp_eproc.e_ucred.cr_uid)
    }

    private typealias PidPathFn = @convention(c) (Int32, UnsafeMutableRawPointer?, UInt32) -> Int32
    private static let procPidPath: PidPathFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2) /* RTLD_DEFAULT */, "proc_pidpath") else { return nil }
        return unsafeBitCast(sym, to: PidPathFn.self)
    }()

    static func pidPath(_ pid: Int32) -> String {
        guard let fn = procPidPath else { return "" }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))   // PROC_PIDPATHINFO_MAXSIZE
        let n = fn(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : ""
    }

    private static func cString<T>(_ tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    static func argMax() -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var v: Int32 = 0
        var sz = MemoryLayout<Int32>.size
        if sysctl(&mib, 2, &v, &sz, nil, 0) == 0, v > 0, v < 64 * 1024 * 1024 { return Int(v) }
        return 1024 * 1024
    }

    /// (exec path, argv joined by spaces) from KERN_PROCARGS2:
    /// [argc: Int32][exec path\0][\0 padding][argv0\0argv1\0...][env...]. ("", "") when unreadable.
    static func arguments(_ pid: Int32, buf: inout [UInt8]) -> (String, String) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buf.count
        let rc = buf.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard rc == 0, size > MemoryLayout<Int32>.size, size <= buf.count else { return ("", "") }
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: buf[0..<4]) }
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }    // exec path
        let exec = String(decoding: buf[4..<i], as: UTF8.self)
        while i < size && buf[i] == 0 { i += 1 }    // padding
        var parts: [String] = []
        while i < size && parts.count < Int(max(0, argc)) {
            let s = i
            while i < size && buf[i] != 0 { i += 1 }
            parts.append(String(decoding: buf[s..<i], as: UTF8.self))
            i += 1
        }
        return (exec, parts.joined(separator: " "))
    }
}

extension AppMatcher.Kind {
    /// Name / path rules also pick helpers of the same `.app`; command-line rules do not
    /// (interpreters such as Python.app or node are shared by unrelated scripts).
    var expandsToBundle: Bool {
        switch self {
        case .name, .path: return true
        case .args, .cmd, .all, .never: return false
        }
    }
}
