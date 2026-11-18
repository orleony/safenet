import Foundation
import Network
import SystemConfiguration
#if canImport(Darwin)
import Darwin
#endif

// MARK: Command runner

public protocol CommandRunner {
    /// Runs an executable with fixed arguments; returns stdout, or nil on failure/timeout.
    func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String?
}

/// Process-based runner. A hung command is terminated (then killed) after `timeout`.
public struct ProcessCommandRunner: CommandRunner {
    public init() {}
    public func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        var data = Data()
        let readDone = DispatchSemaphore(value: 0)
        let reader = out.fileHandleForReading
        DispatchQueue.global().async {
            data = reader.readDataToEndOfFile()
            readDone.signal()
        }
        if done.wait(timeout: .now() + max(0.05, timeout)) == .timedOut {
            p.terminate()
            if done.wait(timeout: .now() + 0.5) == .timedOut { kill(p.processIdentifier, SIGKILL); _ = done.wait(timeout: .now() + 0.5) }
            _ = readDone.wait(timeout: .now() + 0.5)
            return nil
        }
        _ = readDone.wait(timeout: .now() + 1)
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: Parsing / system data

public struct InterfaceInfo: Equatable {
    public struct V4: Equatable {
        public var address: String
        public var prefix: Int
        public init(address: String, prefix: Int) { self.address = address; self.prefix = prefix }
    }
    public var name: String
    public var isUp: Bool
    public var ipv4: [V4]
    public var ipv6: [String]
    public init(name: String, isUp: Bool, ipv4: [V4], ipv6: [String]) {
        self.name = name; self.isUp = isUp; self.ipv4 = ipv4; self.ipv6 = ipv6
    }
}

/// `route -n get default` -> gateway (IPv4 only) and interface. A point-to-point tunnel has no gateway line.
public func parseRouteDefault(_ output: String) -> (gateway: String?, interface: String?) {
    var gw: String?, ifc: String?
    for raw in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard let c = line.firstIndex(of: ":") else { continue }
        let k = line[..<c].trimmingCharacters(in: .whitespaces)
        let v = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
        if k == "gateway" {
            var a = in_addr()
            if inet_pton(AF_INET, v, &a) == 1 { gw = v }
        } else if k == "interface", !v.isEmpty { ifc = v }
    }
    return (gw, ifc)
}

/// Converts a State:/Network/Global/Proxies dictionary. nil when no proxy of any kind is enabled.
public func parseProxies(_ d: [String: Any]) -> ProxyInfo? {
    func on(_ k: String) -> Bool { (d[k] as? NSNumber)?.intValue == 1 }
    func hp(_ host: String, _ port: String) -> String? {
        guard let h = d[host] as? String, !h.isEmpty else { return nil }
        if let p = (d[port] as? NSNumber)?.intValue { return "\(h):\(p)" }
        return h
    }
    var p = ProxyInfo()
    if on("HTTPEnable") { p.http = hp("HTTPProxy", "HTTPPort") }
    if on("HTTPSEnable") { p.https = hp("HTTPSProxy", "HTTPSPort") }
    if on("SOCKSEnable") { p.socks = hp("SOCKSProxy", "SOCKSPort") }
    if on("ProxyAutoConfigEnable"), let u = d["ProxyAutoConfigURLString"] as? String, !u.isEmpty { p.pacURL = u }
    return p == ProxyInfo() ? nil : p
}

public enum SnapshotBuilder {
    /// Builds a snapshot from already-gathered data. Shell commands only go through `runner`.
    /// Tunnel = a `utun*`/ppp/ipsec interface that is up and has an IPv4 address or a non-link-local IPv6 address
    /// (macOS keeps idle utun interfaces with only fe80:: addresses, which are not VPNs), or the default route
    /// itself leaves through such an interface.
    public static func build(interfaces: [InterfaceInfo], pathSatisfied: Bool, proxy: ProxyInfo?, runner: CommandRunner) -> NetSnapshot {
        let route = runner.run("/sbin/route", ["-n", "get", "default"], timeout: 2).map(parseRouteDefault) ?? (gateway: nil, interface: nil)
        var mac: String?
        if let gw = route.gateway {   // validated IPv4 literal by parseRouteDefault; fixed argv, no shell
            mac = runner.run("/usr/sbin/arp", ["-n", gw], timeout: 2).flatMap { parseARP($0, gateway: gw) }
        }
        var subnet: String?
        if let n = route.interface, let v4 = interfaces.first(where: { $0.name == n })?.ipv4.first {
            subnet = networkCIDR(v4.address, v4.prefix)
        }
        let tunnelByIface = interfaces.contains { i in
            isTunnelInterface(i.name) && i.isUp && (!i.ipv4.isEmpty || i.ipv6.contains { !IPMatcher.matches($0, entry: "fe80::/10") })
        }
        let tunnelByRoute = route.interface.map { isTunnelInterface($0) } ?? false
        let v6 = interfaces.contains { i in
            i.isUp && !isTunnelInterface(i.name) && i.ipv6.contains { IPMatcher.parse($0).map { $0.count == 16 && ($0[0] & 0xE0) == 0x20 } ?? false }
        }
        return NetSnapshot(online: pathSatisfied, hasTunnel: tunnelByIface || tunnelByRoute, gatewayIP: route.gateway,
                           gatewayMAC: mac, subnet: subnet, interface: route.interface, hasGlobalIPv6: v6, proxy: proxy)
    }

    static func networkCIDR(_ addr: String, _ prefix: Int) -> String? {
        guard var b = IPMatcher.parse(addr), b.count == 4, (0...32).contains(prefix) else { return nil }
        var bits = prefix
        for i in 0..<4 {
            let m: UInt8 = bits >= 8 ? 0xFF : (bits <= 0 ? 0 : UInt8(truncatingIfNeeded: 0xFF << (8 - bits)))
            b[i] &= m; bits -= 8
        }
        return "\(b[0]).\(b[1]).\(b[2]).\(b[3])/\(prefix)"
    }

    /// Real interface list via getifaddrs (loopback skipped).
    public static func systemInterfaces() -> [InterfaceInfo] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var order: [String] = []
        var map: [String: InterfaceInfo] = [:]
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cur {
            cur = p.pointee.ifa_next
            let name = String(cString: p.pointee.ifa_name)
            let flags = Int32(p.pointee.ifa_flags)
            if flags & IFF_LOOPBACK != 0 { continue }
            var info = map[name] ?? InterfaceInfo(name: name, isUp: false, ipv4: [], ipv6: [])
            if map[name] == nil { order.append(name) }
            info.isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0
            if let sa = p.pointee.ifa_addr {
                if Int32(sa.pointee.sa_family) == AF_INET {
                    var a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    var prefix = 32
                    if let m = p.pointee.ifa_netmask {
                        prefix = m.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr).nonzeroBitCount }
                    }
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count)) != nil {
                        info.ipv4.append(.init(address: String(cString: buf), prefix: prefix))
                    }
                } else if Int32(sa.pointee.sa_family) == AF_INET6 {
                    var a = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    if inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count)) != nil { info.ipv6.append(String(cString: buf)) }
                }
            }
            map[name] = info
        }
        return order.compactMap { map[$0] }
    }

    /// Current system proxy settings from the dynamic store.
    public static func systemProxy() -> ProxyInfo? {
        guard let store = SCDynamicStoreCreate(nil, "SafeNet.proxy" as CFString, nil, nil),
              let d = SCDynamicStoreCopyValue(store, "State:/Network/Global/Proxies" as CFString) as? [String: Any] else { return nil }
        return parseProxies(d)
    }
}

/// `scutil --dns` through a runner. nil = unknown (command failed or timed out); an empty array is also "unknown" to the sampler.
public func currentDNSResolvers(runner: CommandRunner = ProcessCommandRunner()) -> [DNSResolver]? {
    runner.run("/usr/sbin/scutil", ["--dns"], timeout: 3).map(parseScutilDNS)
}

// MARK: Monitor

/// Weak holder so SCDynamicStore callbacks never touch a deallocated monitor.
private final class WeakMonitor { weak var m: NetworkMonitor?; init(_ m: NetworkMonitor) { self.m = m } }

/// Watches NWPathMonitor + SystemConfiguration (global IPv4/IPv6/DNS/Proxies) and reports a fresh snapshot
/// ~50 ms after the last change event. `onChange` fires only when the snapshot differs from the previous one
/// (always for the first after `start()`), on a separate callback queue, so `stop()` may be called from
/// inside `onChange` (or from any thread) without deadlock. After `stop()` returns no new callback is started.
public final class NetworkMonitor {
    private let onChange: (NetSnapshot) -> Void
    private let queue = DispatchQueue(label: "safenet.networkmonitor")
    private let callbackQueue = DispatchQueue(label: "safenet.networkmonitor.callback")
    private let debounce: TimeInterval
    private let lock = NSLock()
    // guarded by `lock`
    private var pathMonitor: NWPathMonitor?
    private var store: SCDynamicStore?
    private var pending: DispatchWorkItem?
    private var pathSatisfied = false
    private var last: NetSnapshot?
    private var running = false
    private var generation = 0

    /// `snapshotSource` is injectable for offline tests; the default builds the real snapshot
    /// (receives whether NWPath is satisfied).
    public init(debounce: TimeInterval = 0.05, runner: CommandRunner = ProcessCommandRunner(),
                snapshotSource: ((Bool) -> NetSnapshot)? = nil, onChange: @escaping (NetSnapshot) -> Void) {
        self.debounce = debounce; self.onChange = onChange
        let src = snapshotSource ?? { sat in
            SnapshotBuilder.build(interfaces: SnapshotBuilder.systemInterfaces(), pathSatisfied: sat,
                                  proxy: SnapshotBuilder.systemProxy(), runner: runner)
        }
        self.sourceWithPath = src
    }
    private let sourceWithPath: (Bool) -> NetSnapshot

    public func start() {
        lock.lock()
        if running { lock.unlock(); return }
        running = true; generation += 1; last = nil
        let gen = generation

        let pm = NWPathMonitor()
        pm.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            self.lock.lock(); self.pathSatisfied = path.status == .satisfied; self.lock.unlock()
            self.schedule(gen)
        }
        pm.start(queue: queue)
        pathMonitor = pm

        var ctx = SCDynamicStoreContext(version: 0, info: Unmanaged.passRetained(WeakMonitor(self)).toOpaque(),
                                        retain: nil,
                                        release: { Unmanaged<WeakMonitor>.fromOpaque($0).release() },
                                        copyDescription: nil)
        let cb: SCDynamicStoreCallBack = { _, _, info in
            guard let info = info else { return }
            let w = Unmanaged<WeakMonitor>.fromOpaque(info).takeUnretainedValue()
            if let me = w.m { me.scheduleCurrent() }
        }
        if let s = SCDynamicStoreCreate(nil, "SafeNet.monitor" as CFString, cb, &ctx) {
            let keys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6",
                        "State:/Network/Global/DNS", "State:/Network/Global/Proxies"] as CFArray
            SCDynamicStoreSetNotificationKeys(s, keys, nil)
            SCDynamicStoreSetDispatchQueue(s, queue)
            store = s
        } else {
            Unmanaged<WeakMonitor>.fromOpaque(ctx.info!).release()
        }
        lock.unlock()
        schedule(gen)
    }

    /// Safe from any thread, including from inside `onChange`.
    public func stop() {
        lock.lock()
        running = false; generation += 1
        let pm = pathMonitor, s = store, p = pending
        pathMonitor = nil; store = nil; pending = nil; last = nil
        lock.unlock()
        p?.cancel(); pm?.cancel()
        if let s = s { SCDynamicStoreSetDispatchQueue(s, nil) }
    }

    deinit {
        pathMonitor?.cancel()
        if let s = store { SCDynamicStoreSetDispatchQueue(s, nil) }
        pending?.cancel()
    }

    /// Force a re-evaluation now.
    public func refresh() {
        lock.lock(); let gen = generation, r = running; lock.unlock()
        guard r else { return }
        queue.async { [weak self] in self?.emit(gen) }
    }

    fileprivate func scheduleCurrent() {
        lock.lock(); let gen = generation; lock.unlock()
        schedule(gen)
    }

    private func schedule(_ gen: Int) {
        lock.lock()
        guard running, gen == generation else { lock.unlock(); return }
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.emit(gen) }
        pending = w
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounce, execute: w)
    }

    private func emit(_ gen: Int) {
        lock.lock()
        guard running, gen == generation else { lock.unlock(); return }
        let sat = pathSatisfied
        lock.unlock()
        let snap = sourceWithPath(sat)
        lock.lock()
        guard running, gen == generation, snap != last else { lock.unlock(); return }
        last = snap
        lock.unlock()
        callbackQueue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock(); let ok = self.running && self.generation == gen; self.lock.unlock()
            if ok { self.onChange(snap) }
        }
    }
}
