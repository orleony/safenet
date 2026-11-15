import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Minimal description of the system proxy configuration ("host:port" strings).
public struct ProxyInfo: Equatable {
    public var http: String?
    public var https: String?
    public var socks: String?
    public var pacURL: String?
    public init(http: String? = nil, https: String? = nil, socks: String? = nil, pacURL: String? = nil) {
        self.http = http; self.https = https; self.socks = socks; self.pacURL = pacURL
    }
}

/// What the network looks like right now. `gatewayMAC` is lowercase zero-padded colon form.
public struct NetSnapshot: Equatable {
    public var online: Bool
    /// A VPN-like tunnel interface is up (see `SnapshotBuilder`).
    public var hasTunnel: Bool
    public var gatewayIP: String?
    public var gatewayMAC: String?
    /// CIDR of the default-route interface's IPv4 network, e.g. "192.168.1.0/24".
    public var subnet: String?
    public var interface: String?
    /// A global-scope (2000::/3) IPv6 address sits on a non-tunnel interface.
    public var hasGlobalIPv6: Bool
    public var proxy: ProxyInfo?
    public init(online: Bool, hasTunnel: Bool, gatewayIP: String?, gatewayMAC: String?, subnet: String? = nil,
                interface: String? = nil, hasGlobalIPv6: Bool = false, proxy: ProxyInfo?) {
        self.online = online; self.hasTunnel = hasTunnel; self.gatewayIP = gatewayIP; self.gatewayMAC = gatewayMAC
        self.subnet = subnet; self.interface = interface; self.hasGlobalIPv6 = hasGlobalIPv6; self.proxy = proxy
    }
}

/// Normalises "A4:2B:b0:1:2:3" (also '-' separated) to "a4:2b:b0:01:02:03".
/// Returns nil for anything that is not 6 hex octets, and for the all-zero / broadcast addresses.
public func normalizeMAC(_ s: String) -> String? {
    let parts = s.trimmingCharacters(in: .whitespaces).split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == "-" })
    guard parts.count == 6 else { return nil }
    var out: [String] = []
    for p in parts {
        guard (1...2).contains(p.utf8.count), p.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) || ($0 >= 65 && $0 <= 70) })
        else { return nil }
        out.append((p.count == 1 ? "0" : "") + p.lowercased())
    }
    let mac = out.joined(separator: ":")
    if mac == "00:00:00:00:00:00" || mac == "ff:ff:ff:ff:ff:ff" { return nil }
    return mac
}

/// Extracts the gateway's MAC from `arp -n <gw>` / `arp -an` output.
/// Line format: `? (192.168.1.1) at a4:2b:b0:1:2:3 on en0 ifscope [ethernet]`. `(incomplete)` entries yield nil.
public func parseARP(_ output: String, gateway: String) -> String? {
    var a = in_addr()
    guard inet_pton(AF_INET, gateway, &a) == 1 else { return nil }
    let needle = "(\(gateway))"
    for line in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
        let words = line.split(separator: " ").map(String.init)
        guard let i = words.firstIndex(of: needle), i + 2 < words.count, words[i + 1] == "at" else { continue }
        return normalizeMAC(words[i + 2])
    }
    return nil
}

/// Trusted only if ALL hold: the gateway MAC equals the stored MAC, the gateway IP equals the stored IP,
/// and the gateway lies inside the stored subnet. An IP (or MAC) alone never grants trust.
public func isTrusted(_ s: NetSnapshot, _ list: [TrustedNetwork]) -> Bool {
    guard let gw = s.gatewayIP, let rawMAC = s.gatewayMAC, let mac = normalizeMAC(rawMAC) else { return false }
    for n in list {
        guard let nm = normalizeMAC(n.mac), nm == mac, n.ip == gw,
              n.subnet.contains("/"), IPMatcher.matches(gw, entry: n.subnet) else { continue }
        return true
    }
    return false
}
