import Foundation
import SafeNetCore

func registerIPCTests() {
    test("testParseAllowIPCountryCurrent") {
        expectEqual(parseCLI(["allow"]), .allow(nil))
        expectEqual(parseCLI(["allow", "1.2.3.4"]), .allow("1.2.3.4"))
        expectEqual(parseCLI(["allow", "185.12.40.0/24"]), .allow("185.12.40.0/24"))
        expectEqual(parseCLI(["allow", "NL"]), .allow("NL"))
        expectEqual(parseCLI(["allow", "2001:db8::/32"]), .allow("2001:db8::/32"))
        expectEqual(parseCLI(["status"]), .status)
        expectEqual(parseCLI(["panel"]), .panel)
        expectEqual(parseCLI(["config"]), .config)
        expectEqual(parseCLI(["version"]), .version)
    }

    test("testUnknownCommandNil") {
        expect(parseCLI([]) == nil)
        expect(parseCLI(["bogus"]) == nil)
        expect(parseCLI(["status", "x"]) == nil, "extra args")
        expect(parseCLI(["allow", "NL", "DE"]) == nil)
        expect(parseCLI(["--watchdog", "1", "x"]) == nil)
        expect(parseCLI(["STATUS"]) == nil)
    }

    test("testRoundTripMessage") {
        for c: CLICommand in [.status, .allow(nil), .allow("1.2.3.4"), .allow("NL"), .panel, .config, .version] {
            let d = encodeMessage(IPCRequest(c))
            expectEqual(d.last, 0x0A)
            expectEqual(d.filter { $0 == 0x0A }.count, 1, "single line")
            try expectEqual(decodeRequest(d), c)
        }
        let r = IPCResponse(ok: true, text: "привет\nмир", data: ["k": "v"])
        let d = encodeMessage(r)
        expectEqual(d.filter { $0 == 0x0A }.count, 1, "newlines in text are escaped")
        try expectEqual(decodeResponse(d), r)
        try expectEqual(decodeResponse(encodeMessage(IPCResponse.error("x"))), IPCResponse(ok: false, text: "x"))
    }

    test("testMalformedTargetsRejected") {
        for bad in ["1.2.3", "256.1.1.1", "1.2.3.4/33", "1.2.3.4/", "/24", "1.2.3.4/24/1", "bad!", "N", "NLD", "N1",
                    "../../x", "1.2.3.4;rm -rf /", "$(id)", "`id`", "a b", "1.2.3.4 ", "-1", "--help", "ü", "1.2.3.4\n",
                    String(repeating: "a", count: 100)] {
            expect(parseCLI(["allow", bad]) == nil, "must reject \(bad)")
        }
    }

    test("testCountryLowercaseNormalised") {
        expectEqual(parseCLI(["allow", "nl"]), .allow("NL"))
        expectEqual(parseCLI(["allow", "Nl"]), .allow("NL"))
    }

    test("testOversizedAndGarbledMessagesRejected") {
        expectThrows { _ = try decodeRequest(Data(repeating: 0x41, count: ipcMaxMessage + 1)) }
        expectThrows { _ = try decodeRequest(Data()) }
        expectThrows { _ = try decodeRequest(Data("not json\n".utf8)) }
        expectThrows { _ = try decodeRequest(Data([0xFF, 0xFE, 0x00, 0x0A])) }
        expectThrows { _ = try decodeRequest(Data("{\"v\":2,\"cmd\":\"status\"}\n".utf8)) }
        expectThrows { _ = try decodeRequest(Data("{\"v\":1,\"cmd\":\"rm\"}\n".utf8)) }
        expectThrows { _ = try decodeRequest(Data("{\"v\":1,\"cmd\":\"allow\",\"arg\":\"../../x\"}\n".utf8)) }
        expectThrows { _ = try decodeRequest(Data("{\"v\":1,\"cmd\":\"status\",\"arg\":\"x\"}\n".utf8)) }
        expectThrows { _ = try decodeRequest(Data("{\"v\":1,\ncmd\":\"status\"}\n".utf8)) }
        expectThrows { _ = try decodeResponse(Data("[]\n".utf8)) }
        try expectEqual(decodeRequest(Data("{\"v\":1,\"cmd\":\"allow\",\"arg\":\"nl\"}\n".utf8)), .allow("NL"))
    }

    test("testParsePauseResumeClose") {
        expectEqual(parseCLI(["pause"]), .pause(nil))
        expectEqual(parseCLI(["pause", "90"]), .pause("90"))
        expectEqual(parseCLI(["pause", "90s"]), .pause("90"))
        expectEqual(parseCLI(["pause", "15m"]), .pause("900"))
        expectEqual(parseCLI(["pause", "2H"]), .pause("7200"))
        expectEqual(parseCLI(["pause", "24h"]), .pause("86400"))
        expectEqual(parseCLI(["pause", "restart"]), .pause("restart"))
        expectEqual(parseCLI(["pause", "until-restart"]), .pause("restart"))
        expectEqual(parseCLI(["resume"]), .resume)
        expectEqual(parseCLI(["close"]), .close)
        for bad in ["0", "0m", "25h", "86401", "-5", "1.5m", "m", "", "5d", "5 m", "1e3", "abc", "9999999h"] {
            expect(parseCLI(["pause", bad]) == nil, "must reject pause \(bad)")
        }
        expect(parseCLI(["pause", "5m", "x"]) == nil)
        expect(parseCLI(["resume", "x"]) == nil)
        expect(parseCLI(["close", "telegram"]) == nil)
        for c: CLICommand in [.pause(nil), .pause("900"), .pause("restart"), .resume, .close] {
            try expectEqual(decodeRequest(encodeMessage(IPCRequest(c))), c)
        }
        expectThrows { _ = try decodeRequest(Data("{\"v\":1,\"cmd\":\"pause\",\"arg\":\"0\"}\n".utf8)) }
        expectThrows { _ = try decodeRequest(Data("{\"v\":1,\"cmd\":\"close\",\"arg\":\"x\"}\n".utf8)) }
        try expectEqual(decodeRequest(Data("{\"v\":1,\"cmd\":\"pause\",\"arg\":\"5m\"}\n".utf8)), .pause("300"))
    }

    test("testUsageText") {
        for w in ["status", "allow", "pause", "resume", "close", "panel", "config", "version"] { expect(cliUsage.contains(w), w) }
        expect(CLICommand.config.isLocal && CLICommand.version.isLocal && !CLICommand.status.isLocal)
    }
}
