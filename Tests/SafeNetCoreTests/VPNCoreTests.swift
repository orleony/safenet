import Foundation
@testable import SafeNetCore

private let uuid = "bf000d23-0752-40b4-affe-68f7707a9661"

private func ob(_ link: String) -> [String: JSONValue] {
    do { return try ProxyLink.parse(link).outbound.object ?? [:] } catch { expect(false, "\(link): \(error)"); return [:] }
}

/// `sing-box check` on a generated config, when the pinned binary is present (scripts/fetch-singbox.sh).
private func singBoxCheck(_ config: JSONValue) -> String? {
    let bin = FileManager.default.currentDirectoryPath + "/vendor/sing-box/sing-box"
    guard FileManager.default.isExecutableFile(atPath: bin) else { return nil }
    let f = FileManager.default.temporaryDirectory.appendingPathComponent("sb-\(UUID().uuidString).json")
    try? config.encoded(pretty: true).write(to: f)
    defer { try? FileManager.default.removeItem(at: f) }
    let p = Process(); p.executableURL = URL(fileURLWithPath: bin); p.arguments = ["check", "-c", f.path]
    let err = Pipe(); p.standardError = err; p.standardOutput = err
    try? p.run(); p.waitUntilExit()
    return p.terminationStatus == 0 ? "" : String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

let vpnSampleLinks = [
    "vless://\(uuid)@nl.example.com:443?type=tcp&security=reality&sni=www.microsoft.com&fp=chrome&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0&sid=0123abcd&flow=xtls-rprx-vision#NL%20Reality",
    "vless://\(uuid)@[2001:db8::1]:8443?type=ws&security=tls&host=cdn.example.com&path=%2Fws%3Fed%3D2048&sni=cdn.example.com#WS",
    "vless://\(uuid)@1.2.3.4:443?type=grpc&serviceName=grpcsvc&security=tls&sni=g.example.com&alpn=h2#gRPC",
    "trojan://p%40ss@tr.example.com:443?sni=tr.example.com&type=ws&path=/tr#Trojan",
    "ss://\(Data("chacha20-ietf-poly1305:secret".utf8).base64EncodedString())@ss.example.com:8388#SS",
    "ss://2022-blake3-aes-256-gcm:YctPZ6U7xPPcU%2Bgp3u%2B0tx%2FtRizJN9K8y%2BuKlW2qjlI%3D@ss2.example.com:443#SS2022",
    "hysteria2://pw@hy.example.com:443?sni=hy.example.com&obfs=salamander&obfs-password=x&insecure=1#HY2",
    "hy2://pw@hy.example.com:443#HY",
    "tuic://\(uuid):pw@tu.example.com:443?congestion_control=bbr&alpn=h3&sni=tu.example.com#TUIC",
    "vmess://" + Data(#"{"v":"2","ps":"VM","add":"vm.example.com","port":"443","id":"\#(uuid)","aid":"0","scy":"auto","net":"ws","host":"vm.example.com","path":"/vm","tls":"tls","sni":"vm.example.com"}"#.utf8).base64EncodedString(),
]

func registerVPNCoreTests() {
    test("testVlessRealityLink") {
        let p = try? ProxyLink.parse(vpnSampleLinks[0])
        expectEqual(p?.name, "NL Reality"); expectEqual(p?.kind, "vless"); expectEqual(p?.port, 443)
        let o = ob(vpnSampleLinks[0])
        expectEqual(o["uuid"], .string(uuid)); expectEqual(o["flow"], "xtls-rprx-vision"); expectEqual(o["tag"], "proxy")
        expectEqual(o["tls"]?["reality"]?["public_key"], "jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0")
        expectEqual(o["tls"]?["server_name"], "www.microsoft.com")
        expectEqual(o["tls"]?["utls"]?["fingerprint"], "chrome")
        expectEqual(o["transport"], nil)
    }
    test("testTransportsAndIPv6Host") {
        let ws = ob(vpnSampleLinks[1])
        expectEqual(ws["server"], "2001:db8::1")
        expectEqual(ws["transport"]?["type"], "ws"); expectEqual(ws["transport"]?["path"], "/ws?ed=2048")
        expectEqual(ws["transport"]?["headers"]?["Host"], "cdn.example.com")
        expectEqual(ob(vpnSampleLinks[2])["transport"]?["service_name"], "grpcsvc")
        expectEqual(ob(vpnSampleLinks[3])["password"], "p@ss")
        expectEqual(ob(vpnSampleLinks[3])["tls"]?["enabled"], true, "trojan is TLS by default")
    }
    test("testShadowsocksForms") {
        let a = ob(vpnSampleLinks[4]); expectEqual(a["method"], "chacha20-ietf-poly1305"); expectEqual(a["password"], "secret")
        let b = ob(vpnSampleLinks[5]); expectEqual(b["method"], "2022-blake3-aes-256-gcm")
        expectEqual(b["password"], "YctPZ6U7xPPcU+gp3u+0tx/tRizJN9K8y+uKlW2qjlI=")
        let legacy = "ss://" + Data("aes-256-gcm:pw@old.example.com:8388".utf8).base64EncodedString() + "#Old"
        expectEqual(ob(legacy)["server"], "old.example.com")
        expectEqual((try? ProxyLink.parse(legacy))?.name, "Old")
    }
    test("testHysteriaTuicVmess") {
        let h = ob(vpnSampleLinks[6]); expectEqual(h["obfs"]?["type"], "salamander"); expectEqual(h["tls"]?["insecure"], true)
        let t = ob(vpnSampleLinks[8]); expectEqual(t["uuid"], .string(uuid)); expectEqual(t["password"], "pw")
        let v = ob(vpnSampleLinks[9]); expectEqual(v["type"], "vmess"); expectEqual(v["transport"]?["path"], "/vm")
        expectEqual((try? ProxyLink.parse(vpnSampleLinks[9]))?.name, "VM")
    }
    test("testUnsupportedLinksExplain") {
        for (link, word) in [("vless://\(uuid)@h.example.com:443?type=xhttp&security=tls#X", "XHTTP"),
                             ("ss://\(Data("rc4-md5:pw".utf8).base64EncodedString())@h.example.com:1#R", "rc4-md5"),
                             ("happ://crypt/abc", "подписки"),
                             ("vless://\(uuid)@h.example.com#nop", "порта"),
                             ("wireguard://x@h:1", "не поддерживается")] {
            do { _ = try ProxyLink.parse(link); expect(false, "must fail: \(link)") }
            catch { expect("\(error)".contains(word), "\(link): \(error)") }
        }
    }
    test("testEveryGeneratedConfigPassesSingBoxCheck") {
        for link in vpnSampleLinks {
            guard let p = try? ProxyLink.parse(link) else { expect(false, link); continue }
            for mode in VPNMode.allCases {
                let r = VPNStartRequest(outbound: p.outbound, mode: mode, appPaths: ["/Claude.app/", "/Visual Studio Code.app/"], appNames: ["node"])
                do { try SingBoxConfig.validate(r) } catch { expect(false, "\(p.name) \(mode): \(error)") }
                if let out = singBoxCheck(SingBoxConfig.build(r)) { expect(out.isEmpty, "\(p.name) \(mode): \(out)") }
            }
        }
    }
    test("testKillSwitchShapeOfConfig") {
        let p = try! ProxyLink.parse(vpnSampleLinks[0])
        let all = SingBoxConfig.build(VPNStartRequest(outbound: p.outbound, mode: .all))
        expectEqual(all["route"]?["final"], "proxy")
        expectEqual(all["dns"]?["final"], "remote")
        guard case .array(let inb)? = all["inbounds"], let tun = inb.first else { return expect(false, "no tun") }
        expectEqual(tun["strict_route"], true); expectEqual(tun["auto_route"], true)
        expect(tun["address"] == .array(SingBoxConfig.tunAddresses), "IPv6 captured too")
        let apps = SingBoxConfig.build(VPNStartRequest(outbound: p.outbound, mode: .apps, appPaths: ["/Claude.app/"]))
        expectEqual(apps["route"]?["final"], "direct")
        expect(String(decoding: apps.encoded(), as: UTF8.self).contains(#"/Claude\\.app/"#), "path fragment as escaped regex")
    }
    test("testHelperRequestValidationBlocksFilesAndChains") {
        let p = try! ProxyLink.parse(vpnSampleLinks[0])
        guard var o = p.outbound.object else { return }
        var tls = o["tls"]!.object!; tls["certificate_path"] = "/etc/master.passwd"; o["tls"] = .object(tls)
        for bad in [JSONValue.object(o),
                    .object(p.outbound.object!.merging(["detour": "direct"]) { $1 }),
                    .object(p.outbound.object!.merging(["type": "direct"]) { $1 }),
                    .object(p.outbound.object!.merging(["tag": "x"]) { $1 })] {
            do { try SingBoxConfig.validate(VPNStartRequest(outbound: bad, mode: .all)); expect(false, "must refuse") } catch {}
        }
        do { try SingBoxConfig.validate(VPNStartRequest(outbound: p.outbound, mode: .apps)); expect(false, "apps mode without apps") } catch {}
    }
    test("testAppSelectorsFromMatchers") {
        let s = SingBoxConfig.appSelectors(["/Claude.app/", "node && args:/@anthropic-ai/claude-code/cli.js", "node && cmd:claude",
                                            "/.local/share/claude/", "Telegram", "args:foo"])
        expectEqual(s.paths, ["/Claude.app/", "/.local/share/claude/"])
        expectEqual(s.names, ["node", "claude", "Telegram"])
        expectEqual(SingBoxConfig.regex(forFragment: "/zoom.us.app/"), #"/zoom\.us\.app/"#)
    }
    test("testSubscriptionDecode") {
        let body = Data((vpnSampleLinks[0] + "\nbroken://x\n" + vpnSampleLinks[6] + "\n").utf8).base64EncodedString()
        let c = try? Subscription.decode(Data(body.utf8), titleHeader: "base64:" + Data("Мой VPN".utf8).base64EncodedString(),
                                         userinfoHeader: "upload=10; download=20; total=1073741824; expire=1800000000")
        expectEqual(c?.profiles.count, 2); expectEqual(c?.skipped.count, 1)
        expectEqual(c?.title, "Мой VPN")
        expectEqual(c?.info?.total, 1073741824); expectEqual(c?.info?.expire, Date(timeIntervalSince1970: 1_800_000_000))
        let plain = try? Subscription.decode(Data(vpnSampleLinks[3].utf8))
        expectEqual(plain?.profiles.first?.kind, "trojan")
        do { _ = try Subscription.decode(Data("proxies:\n  - name: x".utf8)); expect(false, "clash yaml") }
        catch { expect("\(error)".contains("Clash"), "\(error)") }
    }
    test("testProfileIDStable") {
        let a = try! ProxyLink.parse(vpnSampleLinks[0]), b = try! ProxyLink.parse(" " + vpnSampleLinks[0] + "\n")
        expectEqual(a.id, b.id); expectEqual(a.id.count, 16)
        expect(a.id != (try! ProxyLink.parse(vpnSampleLinks[1])).id)
    }
    test("testSingBoxReleaseChecksDownload") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sbr-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = SingBoxRelease.ensure(in: dir, arch: "arm64") { _ in .success(Data("evil".utf8)) }
        if case .failure(let e) = bad { expect(e.description.contains("контрольной"), e.description) } else { expect(false, "must refuse") }
        expectEqual(SingBoxRelease.url("arm64").absoluteString,
                    "https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-darwin-arm64.tar.gz")
        // The real archive (when fetched for tests) unpacks into a ready directory.
        let local = FileManager.default.currentDirectoryPath + "/.build/test-sing-box.tgz"
        if let d = FileManager.default.contents(atPath: local) {
            let ok = SingBoxRelease.ensure(in: dir, arch: "arm64") { _ in .success(d) }
            if case .success(let u) = ok { expect(FileManager.default.isExecutableFile(atPath: u.appendingPathComponent("sing-box").path)) }
            else { expect(false, "\(ok)") }
        }
    }
    test("testVerdictVPNDown") {
        var o = Observation(online: true, ips: [IPAnswer(ip: "1.2.3.4", country: "NL"), IPAnswer(ip: "1.2.3.4", country: "NL")],
                            ipv6Leak: false, dnsLeak: false, routeLeak: false, trustedNetwork: false)
        let allow = AllowList(countries: ["NL"])
        expectEqual(evaluate(o, allow: allow, minAgree: 2, dnsCheck: .warn), .ok)
        o.vpnDown = true
        expectEqual(evaluate(o, allow: allow, minAgree: 2, dnsCheck: .warn), .freeze(.vpnDown))
        o.trustedNetwork = true
        expectEqual(evaluate(o, allow: allow, minAgree: 2, dnsCheck: .warn), .ok, "trusted network: VPN not required")
        o.online = false
        expectEqual(evaluate(o, allow: allow, minAgree: 2, dnsCheck: .warn), .offline)
    }
}
