import Foundation
import SafeNetCore
@testable import SafeNetUI

func registerVPNAppTests() {
    test("testInstallScriptQuotesAndOwnership") {
        let s = VPNInstaller.installScript(.init(executable: "/Applications/Safe Net's.app/Contents/MacOS/SafeNetApp",
                                                 singBoxDir: "/Users/x/Library/Application Support/SafeNet/sing-box-1.14.4-arm64"), uid: 501)
        expect(s.contains(#"'/Applications/Safe Net'\''s.app/Contents/MacOS/SafeNetApp'"#), "single quotes escaped")
        expect(s.contains("chown -R root:wheel"), "root-owned copy")
        expect(s.contains("<string>501</string>"), "allowed uid in the daemon arguments")
        expect(s.contains("launchctl bootstrap system"))
        expect(s.contains("\nSAFENET_PLIST\n"), "heredoc terminator at column 0")
        expectEqual(VPNInstaller.appleScriptString(#"a"b\c"#), #""a\"b\\c""#)
        expect(VPNInstaller.uninstallScript().contains("bootout system/local.safenet.vpn"))
    }
    test("testHelperHandlesRequests") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sup = SingBoxSupervisor(singBox: "/usr/bin/false", workDir: dir.path, logPath: dir.appendingPathComponent("log").path)
        let st = VPNHelperDaemon.handle(Data(#"{"cmd":"status"}"#.utf8), sup)
        expect(st.ok); expectEqual(st.status?.state, .stopped); expectEqual(st.status?.protocolVersion, VPNHelperVersion.protocolVersion)
        expect(!VPNHelperDaemon.handle(Data("garbage".utf8), sup).ok)
        expect(!VPNHelperDaemon.handle(Data(#"{"cmd":"rm"}"#.utf8), sup).ok)
        // An invalid request never reaches sing-box.
        let bad = try! JSONEncoder().encode(VPNHelperRequest(cmd: "start", start: VPNStartRequest(outbound: ["type": "direct", "tag": "proxy", "server": "x"], mode: .all)))
        let r = VPNHelperDaemon.handle(bad, sup)
        expect(!r.ok); expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path))
    }
    test("testSupervisorRunsSingBoxAndReportsItsFailure") {
        let bin = FileManager.default.currentDirectoryPath + "/vendor/sing-box/sing-box"
        guard FileManager.default.isExecutableFile(atPath: bin), getuid() != 0 else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sup = SingBoxSupervisor(singBox: bin, workDir: dir.path, logPath: dir.appendingPathComponent("vpn.log").path)
        let p = try! ProxyLink.parse("trojan://pw@a.example.com:443#A")
        guard case .success(let st) = sup.start(VPNStartRequest(outbound: p.outbound, mode: .all)) else { return expect(false, "start refused") }
        // Not root: the TUN interface cannot be created, sing-box exits, the reason is reported.
        expectEqual(st.state, .failed, "\(st)")
        expect((st.message ?? "").contains("sing-box остановился"), st.message ?? "")
        expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path))
        let perms = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("config.json").path))?[.posixPermissions] as? NSNumber
        expectEqual(perms?.intValue, 0o600)
        expectEqual(sup.stop().state, .stopped)
    }

    test("testVPNSettingsSelectionAndStore") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var s = VPNSettings()
        s.sources = [VPNSource(kind: .link, links: [vpnLink1]), VPNSource(kind: .subscription, url: "https://sub.example.com/x", links: [vpnLink2, "broken"])]
        s.fixSelection()
        expectEqual(s.selectedProfile?.link, vpnLink1)
        expectEqual(s.allProfiles.count, 2, "a broken stored link is skipped")
        expectEqual(s.sources[1].displayTitle, "sub.example.com")
        s.sources.removeFirst(); s.fixSelection()
        expectEqual(s.selectedProfile?.link, vpnLink2, "vanished server: first remaining one")
        let store = VPNStore(url: dir.appendingPathComponent("vpn.json"))
        expect(store.save(s))
        expectEqual(store.load(), s)
        let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("vpn.json").path)
        expectEqual((attrs?[.posixPermissions] as? NSNumber)?.intValue, 0o600, "links hold credentials")
    }
    test("testTunnelSelectorsFromProtectedApps") {
        var c = Config.default
        c.apps = ["claude", "claude-code"]
        c.customApps = [CustomApp(name: "Tool", match: "/Tool.app/")]
        let s = AppState.tunnelSelectors(c)
        expect(s.paths.contains("/Claude.app/")); expect(s.paths.contains("/Tool.app/")); expect(s.names.contains("node"))
    }
}

private let vpnLink1 = "trojan://pw@a.example.com:443#A"
private let vpnLink2 = "trojan://pw@b.example.com:443#B"
