import Foundation
@testable import SafeNetCore

private final class Box<T> { var value: T? }
private func awaitResult<T>(_ op: @escaping () async -> T) -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = Box<T>()
    Task { box.value = await op(); sem.signal() }
    sem.wait()
    return box.value!
}

private func snap(online: Bool = true, tunnel: Bool = false, gw: String? = "192.168.1.1", mac: String? = "a4:2b:b0:01:02:03",
                  v6: Bool = false) -> NetSnapshot {
    NetSnapshot(online: online, hasTunnel: tunnel, gatewayIP: gw, gatewayMAC: mac, subnet: "192.168.1.0/24",
                interface: "en0", hasGlobalIPv6: v6, proxy: nil)
}
private let home = TrustedNetwork(name: "Home", mac: "a4:2b:b0:01:02:03", ip: "192.168.1.1", subnet: "192.168.1.0/24")

private struct FakeFetcher: TraceFetcher {
    let responses: [String: String]
    func fetch(host: String) async throws -> String {
        if let r = responses[host] { return r }
        throw URLError(.cannotConnectToHost)
    }
}
private func trace(_ ip: String, _ loc: String) -> String { "fl=1\nh=x\nip=\(ip)\nts=1\nloc=\(loc)\ncolo=AMS\n" }

private final class FakeRunner: CommandRunner {
    var outputs: [String: String]
    var calls: [String] = []
    init(_ o: [String: String]) { outputs = o }
    func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        let k = ([path] + args).joined(separator: " ")
        calls.append(k)
        return outputs[k]
    }
}

private let routeFixture = """
   route to: default
destination: default
       mask: default
    gateway: 192.168.1.1
  interface: en0
      flags: <UP,GATEWAY,DONE,STATIC,PRIVATE>
"""

private let scutilFixture = """
DNS configuration

resolver #1
  search domain[0] : lan
  nameserver[0] : 192.168.1.1
  nameserver[1] : fe80::1%en0
  if_index : 15 (en0)
  flags    : Request A records
  reach    : 0x00020002 (Reachable,Directly Reachable Address)

resolver #2
  domain   : local
  options  : mdns
  timeout  : 5
  flags    : Request A records
  order    : 300000

DNS configuration (for scoped queries)

resolver #1
  nameserver[0] : 192.168.1.1
  if_index : 15 (en0)
  flags    : Scoped, Request A records
"""

func registerNetTests() {
    // MARK: ARP
    test("testParseARPExtractsMAC") {
        let out = "? (192.168.1.1) at a4:2b:b0:1:2:3 on en0 ifscope [ethernet]\n"
        expectEqual(parseARP(out, gateway: "192.168.1.1"), "a4:2b:b0:01:02:03")
    }
    test("testParseARPNormalisesUppercaseAndPads") {
        let out = "? (10.0.0.1) at A4:B:C:D:E:F on en0 ifscope [ethernet]"
        expectEqual(parseARP(out, gateway: "10.0.0.1"), "a4:0b:0c:0d:0e:0f")
    }
    test("testParseARPIncompleteIsNil") {
        expectEqual(parseARP("? (192.168.1.1) at (incomplete) on en0 ifscope [ethernet]", gateway: "192.168.1.1"), nil)
    }
    test("testParseARPPicksRequestedGatewayOnly") {
        let out = "? (192.168.1.10) at 11:11:11:11:11:11 on en0 ifscope [ethernet]\n? (192.168.1.1) at 22:22:22:22:22:22 on en0 ifscope [ethernet]\n"
        expectEqual(parseARP(out, gateway: "192.168.1.1"), "22:22:22:22:22:22")
        expectEqual(parseARP(out, gateway: "192.168.1.2"), nil)
        expectEqual(parseARP(out, gateway: "not-an-ip"), nil)
    }
    test("testParseARPRejectsBroadcastAndGarbage") {
        expectEqual(parseARP("? (1.1.1.1) at ff:ff:ff:ff:ff:ff on en0", gateway: "1.1.1.1"), nil)
        expectEqual(parseARP("? (1.1.1.1) at zz:1:2:3:4:5 on en0", gateway: "1.1.1.1"), nil)
        expectEqual(parseARP("? (1.1.1.1) at 1:2:3:4:5 on en0", gateway: "1.1.1.1"), nil)
    }

    // MARK: Trusted networks
    test("testIsTrustedMatchesMACAndSubnet") {
        expect(isTrusted(snap(), [home]))
        expect(isTrusted(snap(mac: "A4:2B:B0:1:2:3"), [home]), "case/padding differences are normalised")
    }
    test("testSameGatewayIPDifferentMACNotTrusted") {
        expect(!isTrusted(snap(mac: "de:ad:be:ef:00:01"), [home]))
    }
    test("testIPAloneNeverTrusted") {
        expect(!isTrusted(snap(mac: nil), [home]))
        expect(!isTrusted(snap(gw: nil, mac: nil), [home]))
    }
    test("testSameMACDifferentSubnetNotTrusted") {
        expect(!isTrusted(snap(gw: "10.0.0.1"), [home]))
        let other = TrustedNetwork(name: "X", mac: "a4:2b:b0:01:02:03", ip: "192.168.1.1", subnet: "10.9.0.0/16")
        expect(!isTrusted(snap(), [other]), "gateway outside the configured subnet")
    }
    test("testIsTrustedRejectsMalformedConfig") {
        let bad = TrustedNetwork(name: "B", mac: "garbage", ip: "192.168.1.1", subnet: "192.168.1.0/24")
        expect(!isTrusted(snap(), [bad]))
        expect(!isTrusted(snap(), []))
    }

    // MARK: Trace
    test("testParseTraceExtractsIPAndLoc") {
        let r = parseTrace("fl=1\nh=api.anthropic.com\nip=203.0.113.7\nts=1\nvisit_scheme=https\nloc=nl\ncolo=AMS\n")
        expectEqual(r?.ip, "203.0.113.7")
        expectEqual(r?.loc, "NL")
        expectEqual(parseTrace("ip=2001:db8::1\nloc=DE")?.ip, "2001:db8::1")
    }
    test("testParseTraceMalformedIsNil") {
        expect(parseTrace("loc=NL\n") == nil, "missing ip")
        expect(parseTrace("ip=999.1.1.1\nloc=NL") == nil, "bad ip")
        expect(parseTrace("ip=1.2.3.4\nloc=\u{00DC}S") == nil, "non-ascii loc")
        expect(parseTrace("ip=1.2.3.4\nloc=NLD") == nil, "long loc")
        expect(parseTrace("ip=1.2.3.4") == nil, "missing loc")
        expect(parseTrace("<html>blocked</html>") == nil)
    }

    // MARK: Route probe
    test("testRouteProbeReportsErrorsAsErrors") {
        let p = RouteProbe(fetcher: FakeFetcher(responses: ["claude.ai": trace("203.0.113.7", "NL"), "chatgpt.com": "garbage"]), timeout: 2)
        let r = awaitResult { await p.check(hosts: ["claude.ai", "chatgpt.com", "api.openai.com"]) }
        expectEqual(r.map { $0.host }, ["claude.ai", "chatgpt.com", "api.openai.com"])
        expectEqual(r[0].ip, "203.0.113.7"); expectEqual(r[0].country, "NL"); expect(r[0].error == nil)
        for i in 1...2 { expect(r[i].error != nil && r[i].ip == nil && r[i].country == nil, "host \(i) must be an error") }
    }
    test("testRouteProbeRejectsBadHostName") {
        let p = RouteProbe(fetcher: FakeFetcher(responses: [:]), timeout: 1)
        let r = awaitResult { await p.check(hosts: ["evil.com/x?y", ""]) }
        expect(r.count == 2 && r.allSatisfy { $0.error != nil })
    }
    test("testRouteProbeOnlyContactsAllowedAIHosts") {
        final class Rec: TraceFetcher { var hosts: [String] = []; let l = NSLock()
            func note(_ h: String) { l.lock(); hosts.append(h); l.unlock() }
            func fetch(host: String) async throws -> String { note(host); return "ip=1.2.3.4\nloc=NL" } }
        let rec = Rec()
        let bad = ["127.0.0.1", "localhost", "[::1]", "evil.example", "CLAUDE.AI.evil.com", "169.254.169.254", "claude.ai.", "8.8.8.8"]
        let r = awaitResult { await RouteProbe(fetcher: rec, timeout: 1).check(hosts: bad + ["claude.ai"]) }
        expectEqual(rec.hosts, ["claude.ai"])
        expectEqual(r.filter { $0.error != nil }.count, bad.count)
        expect(r.last?.error == nil)
    }
    test("testTraceFetcherRefusesRedirects") {
        let d = NoRedirectDelegate()
        let url = URL(string: "https://claude.ai/cdn-cgi/trace")!
        let resp = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://evil.example/"])!
        var called = false, got: URLRequest? = URLRequest(url: url)
        let t = URLSession.shared.dataTask(with: url)
        d.urlSession(URLSession.shared, task: t, willPerformHTTPRedirection: resp,
                     newRequest: URLRequest(url: URL(string: "https://evil.example/")!)) { got = $0; called = true }
        t.cancel()
        expect(called && got == nil)
    }
    test("testRouteProbeTimeout") {
        struct Slow: TraceFetcher {
            func fetch(host: String) async throws -> String { try await Task.sleep(nanoseconds: 5_000_000_000); return "" }
        }
        let t0 = Date()
        let r = awaitResult { await RouteProbe(fetcher: Slow(), timeout: 0.3).check(hosts: ["claude.ai"]) }
        expect(Date().timeIntervalSince(t0) < 2)
        expect(r.first?.error != nil)
    }
    test("testRouteLeakWhenTraceReturnsDisallowedIP") {
        let allow = AllowList(ips: ["203.0.113.7"], countries: [])
        let ok = RouteResult(host: "a", ip: "203.0.113.7", country: "NL", error: nil)
        let bad = RouteResult(host: "b", ip: "198.51.100.9", country: "RU", error: nil)
        let err = RouteResult(host: "c", ip: nil, country: nil, error: "x")
        expect(!detectRouteLeak([ok], allow: allow))
        expect(detectRouteLeak([ok, bad], allow: allow), "one bad result")
        expect(!detectRouteLeak([ok, err], allow: allow), "partial errors ignored")
        expect(detectRouteLeak([err], allow: allow), "all errors = unconfirmed")
        expect(detectRouteLeak([err, err], allow: allow))
        expect(detectRouteLeak([], allow: allow), "empty = unconfirmed")
        expect(!detectRouteLeak(nil, allow: allow), "nil = not evaluated")
        expect(!detectRouteLeak([RouteResult(host: "b", ip: "198.51.100.9", country: "NL", error: nil)],
                                allow: AllowList(ips: [], countries: ["NL"])), "allowed by country")
        expect(detectRouteLeak([bad], allow: AllowList()), "empty allow list allows nothing")
    }

    // MARK: IPv6
    test("testIPv6LeakWhenV6AddressOutsideAllowed") {
        let allow = AllowList(ips: ["203.0.113.7"], countries: [])
        let v4 = IPAnswer(ip: "203.0.113.7", country: "NL")
        let v6 = IPAnswer(ip: "2a02:db8::5", country: "RU")
        expect(detectIPv6Leak(answers: [v4, v6], allow: allow), "observed disallowed v6 is a leak regardless of local scan")
        expect(!detectIPv6Leak(answers: [v4], allow: allow), "no v6 answer")
        expect(!detectIPv6Leak(answers: [v4, IPAnswer(ip: "2a02:db8::5", country: "NL")],
                               allow: AllowList(ips: ["2a02:db8::/32"], countries: [])), "v6 allowed by CIDR")
    }

    // MARK: DNS
    test("testParseScutilDNS") {
        let r = parseScutilDNS(scutilFixture)
        expectEqual(r.count, 3)
        expectEqual(r[0], DNSResolver(address: "192.168.1.1", interface: "en0", scoped: false))
        expectEqual(r[1], DNSResolver(address: "fe80::1", interface: "en0", scoped: false))
        expectEqual(r[2], DNSResolver(address: "192.168.1.1", interface: "en0", scoped: true))
    }
    test("testDNSLeakHeuristic") {
        let router = DNSResolver(address: "192.168.1.1", interface: "en0", scoped: false)
        let routerScoped = DNSResolver(address: "192.168.1.1", interface: "en0", scoped: true)
        expect(!detectDNSLeak(resolvers: [router, routerScoped], hasTunnel: false), "no tunnel: nothing to leak around")
        expect(detectDNSLeak(resolvers: [router, routerScoped], hasTunnel: true), "physical DNS used while tunnel is up")
        expect(detectDNSLeak(resolvers: [DNSResolver(address: "8.8.8.8", interface: "en0", scoped: false)], hasTunnel: true))
        expect(!detectDNSLeak(resolvers: [DNSResolver(address: "10.8.0.1", interface: "utun4", scoped: false), routerScoped], hasTunnel: true),
               "tunnel resolver is fine, scoped physical one is not the default")
        expect(!detectDNSLeak(resolvers: [DNSResolver(address: "1.1.1.1", interface: "utun4", scoped: false)], hasTunnel: true))
        expect(!detectDNSLeak(resolvers: [DNSResolver(address: "198.18.0.1", interface: nil, scoped: false),
                                          DNSResolver(address: "198.18.0.1", interface: "en0", scoped: true)], hasTunnel: true), "fake-ip DNS")
        expect(!detectDNSLeak(resolvers: [DNSResolver(address: "127.0.0.1", interface: nil, scoped: false), routerScoped], hasTunnel: true))
        expect(!detectDNSLeak(resolvers: [DNSResolver(address: "8.8.8.8", interface: nil, scoped: false)], hasTunnel: true),
               "unknown interface and not a physical DNS: cannot tell, not reported")
    }

    // MARK: Route / system parsing
    test("testParseRouteDefault") {
        let r = parseRouteDefault(routeFixture)
        expectEqual(r.gateway, "192.168.1.1"); expectEqual(r.interface, "en0")
        let p2p = parseRouteDefault("destination: default\n  interface: utun3\n")
        expectEqual(p2p.gateway, nil); expectEqual(p2p.interface, "utun3")
        expectEqual(parseRouteDefault("gateway: fe80::1%en0\ninterface: en0").gateway, nil)
        expectEqual(parseRouteDefault("").interface, nil)
    }
    test("testParseProxies") {
        expect(parseProxies([:]) == nil)
        expect(parseProxies(["HTTPEnable": 0, "HTTPProxy": "x"]) == nil)
        let p = parseProxies(["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 8080,
                              "SOCKSEnable": 1, "SOCKSProxy": "10.0.0.2", "SOCKSPort": 1080,
                              "ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "http://pac/x.pac"])
        expectEqual(p, ProxyInfo(http: nil, https: "127.0.0.1:8080", socks: "10.0.0.2:1080", pacURL: "http://pac/x.pac"))
    }
    test("testSnapshotBuilderWithFakeSystem") {
        let ifs = [
            InterfaceInfo(name: "en0", isUp: true, ipv4: [InterfaceInfo.V4(address: "192.168.1.23", prefix: 24)],
                          ipv6: ["fe80::1", "2a02:db8::23"]),
            InterfaceInfo(name: "utun3", isUp: true, ipv4: [InterfaceInfo.V4(address: "10.8.0.2", prefix: 24)], ipv6: []),
            InterfaceInfo(name: "utun0", isUp: true, ipv4: [], ipv6: ["fe80::abcd"]),
        ]
        let runner = FakeRunner([
            "/sbin/route -n get default": routeFixture,
            "/usr/sbin/arp -n 192.168.1.1": "? (192.168.1.1) at a4:2b:b0:1:2:3 on en0 ifscope [ethernet]",
        ])
        let s = SnapshotBuilder.build(interfaces: ifs, pathSatisfied: true, proxy: nil, runner: runner)
        expectEqual(s, NetSnapshot(online: true, hasTunnel: true, gatewayIP: "192.168.1.1", gatewayMAC: "a4:2b:b0:01:02:03",
                                   subnet: "192.168.1.0/24", interface: "en0", hasGlobalIPv6: true, proxy: nil))
        // Only a system link-local utun (iCloud relay etc.) is not a VPN tunnel.
        let s2 = SnapshotBuilder.build(interfaces: [ifs[0], ifs[2]], pathSatisfied: true, proxy: nil, runner: runner)
        expectEqual(s2.hasTunnel, false)
        // Offline, route command failed: no gateway, ARP never invoked.
        let r2 = FakeRunner([:])
        let s3 = SnapshotBuilder.build(interfaces: [], pathSatisfied: false, proxy: nil, runner: r2)
        expectEqual(s3.online, false); expectEqual(s3.gatewayIP, nil); expectEqual(s3.gatewayMAC, nil)
        expectEqual(r2.calls, ["/sbin/route -n get default"])
    }
    test("testCommandRunnerTimeoutAndOutput") {
        let r = ProcessCommandRunner()
        expectEqual(r.run("/bin/echo", ["hi"], timeout: 2), "hi\n")
        let t0 = Date()
        expect(r.run("/bin/sleep", ["5"], timeout: 0.3) == nil)
        expect(Date().timeIntervalSince(t0) < 2)
        expect(r.run("/nonexistent/binary", [], timeout: 1) == nil)
    }

    // MARK: Observation mapping
    test("testMakeObservationMapping") {
        var cfg = Config.default
        cfg.allow = AllowList(ips: ["203.0.113.7"], countries: [])
        cfg.trustedNetworks = [home]
        let v4 = IPAnswer(ip: "203.0.113.7", country: "NL")
        let v6 = IPAnswer(ip: "2a02:db8::5", country: "RU")
        let routeBad = RouteResult(host: "claude.ai", ip: "198.51.100.9", country: "RU", error: nil)
        let router = DNSResolver(address: "192.168.1.1", interface: "en0", scoped: false)

        let clean = NetworkSampler.makeObservation(snapshot: snap(tunnel: true, mac: "de:ad:be:ef:00:01", v6: true), answers: [v4],
                                                   routes: nil, resolvers: [DNSResolver(address: "10.8.0.1", interface: "utun4", scoped: false)], allow: cfg.allow, config: cfg)
        expectEqual(clean, Observation(online: true, ips: [v4], ipv6Leak: false, dnsLeak: false, routeLeak: false, trustedNetwork: false))

        let leaky = NetworkSampler.makeObservation(snapshot: snap(tunnel: true, mac: "de:ad:be:ef:00:01", v6: true), answers: [v4, v6],
                                                   routes: [routeBad], resolvers: [router], allow: cfg.allow, config: cfg)
        expect(leaky.ipv6Leak && leaky.dnsLeak && leaky.routeLeak && !leaky.trustedNetwork)
        expectEqual(leaky.ips, [v4, v6])

        var off = cfg; off.checkIPv6 = false; off.dnsCheck = .off; off.routeCheck = false
        let disabled = NetworkSampler.makeObservation(snapshot: snap(tunnel: true, mac: "de:ad:be:ef:00:01", v6: true), answers: [v4, v6],
                                                      routes: [routeBad], resolvers: [router], allow: off.allow, config: off)
        expect(!disabled.ipv6Leak && !disabled.dnsLeak && !disabled.routeLeak)

        let trusted = NetworkSampler.makeObservation(snapshot: snap(), answers: [], routes: nil, resolvers: nil, allow: cfg.allow, config: cfg)
        expect(trusted.trustedNetwork && trusted.online)
        let offline = NetworkSampler.makeObservation(snapshot: snap(online: false), answers: [], routes: nil, resolvers: nil, allow: cfg.allow, config: cfg)
        expect(!offline.online)
    }

    test("testSamplerRouteAndDNSUnknownRules") {
        var cfg = Config.default
        cfg.allow = AllowList(ips: ["203.0.113.7"], countries: [])
        let tun = snap(tunnel: true, mac: "de:ad:be:ef:00:01")
        let v4 = IPAnswer(ip: "203.0.113.7", country: "NL")
        let okRoute = RouteResult(host: "claude.ai", ip: "203.0.113.7", country: "NL", error: nil)
        let errRoute = RouteResult(host: "claude.ai", ip: nil, country: nil, error: "x")
        let utunDNS = [DNSResolver(address: "10.8.0.1", interface: "utun4", scoped: false)]
        func s(_ c: Config, routes: [RouteResult]?, res: [DNSResolver]?, snapshot: NetSnapshot = tun) -> NetworkSampler.Sample {
            NetworkSampler.makeSample(snapshot: snapshot, answers: [v4], routes: routes, resolvers: res, allow: cfg.allow, config: c)
        }
        expect(!s(cfg, routes: nil, res: utunDNS).observation.routeLeak, "nil = not evaluated")
        expect(s(cfg, routes: [], res: utunDNS).observation.routeLeak, "empty")
        expect(s(cfg, routes: [errRoute], res: utunDNS).observation.routeLeak, "all errors")
        expect(!s(cfg, routes: [errRoute, okRoute], res: utunDNS).observation.routeLeak, "partial errors")
        var noRoute = cfg; noRoute.routeCheck = false
        expect(!s(noRoute, routes: [], res: utunDNS).observation.routeLeak, "check disabled")

        var warn = cfg; warn.dnsCheck = .warn
        var block = cfg; block.dnsCheck = .block
        var off = cfg; off.dnsCheck = .off
        let w = s(warn, routes: nil, res: nil)
        expect(!w.observation.dnsLeak && w.dnsUnknown, "warn: no freeze, but flagged unknown")
        expect(s(warn, routes: nil, res: []).dnsUnknown, "empty = unknown")
        let b = s(block, routes: nil, res: nil)
        expect(b.observation.dnsLeak && b.dnsUnknown, "block: unknown DNS with tunnel freezes")
        expect(s(block, routes: nil, res: []).observation.dnsLeak)
        let o = s(off, routes: nil, res: nil)
        expect(!o.observation.dnsLeak && !o.dnsUnknown)
        let noTun = s(block, routes: nil, res: nil, snapshot: snap(tunnel: false))
        expect(!noTun.observation.dnsLeak && !noTun.dnsUnknown, "no tunnel: DNS unknown is irrelevant")
        expect(!s(block, routes: nil, res: utunDNS).observation.dnsLeak && !s(block, routes: nil, res: utunDNS).dnsUnknown)
    }

    // MARK: Monitor lifecycle (injected snapshot source, offline)
    test("testMonitorStopFromOnChangeDoesNotHang") {
        let done = DispatchSemaphore(value: 0)
        var mon: NetworkMonitor?
        mon = NetworkMonitor(debounce: 0.01, snapshotSource: { _ in snap() }, onChange: { _ in mon?.stop(); done.signal() })
        mon!.start()
        expect(done.wait(timeout: .now() + 5) == .success, "callback delivered and stop() returned")
        mon!.stop()
        mon = nil
    }
    test("testMonitorStartStopStart") {
        let l = NSLock(); var n = 0
        let first = DispatchSemaphore(value: 0), second = DispatchSemaphore(value: 0)
        let mon = NetworkMonitor(debounce: 0.01, snapshotSource: { _ in snap() }, onChange: { _ in
            l.lock(); n += 1; let c = n; l.unlock()
            if c == 1 { first.signal() } else if c == 2 { second.signal() } })
        mon.start(); mon.start()
        expect(first.wait(timeout: .now() + 5) == .success)
        mon.stop(); mon.stop()
        mon.start()
        expect(second.wait(timeout: .now() + 5) == .success, "restart re-emits the first snapshot")
        mon.stop()
        Thread.sleep(forTimeInterval: 0.2)
        l.lock(); let c = n; l.unlock()
        expectEqual(c, 2)
    }
    test("testMonitorDroppedWithoutStopIsSafe") {
        for _ in 0..<20 {
            var mon: NetworkMonitor? = NetworkMonitor(debounce: 0.001, snapshotSource: { _ in snap() }, onChange: { _ in })
            mon!.start()
            Thread.sleep(forTimeInterval: 0.005)
            mon = nil
        }
        Thread.sleep(forTimeInterval: 0.2)
        expect(true)
    }
}
