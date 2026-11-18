import Foundation
import SafeNetCore
@testable import SafeNetUI

func registerAppSupportTests() {
    test("testFlagFromCountryCode") {
        expectEqual(Format.flag("NL"), "🇳🇱")
        expectEqual(Format.flag("ru"), "🇷🇺")
        expectEqual(Format.flag("N"), "")
        expectEqual(Format.flag("1A"), "")
    }

    test("testMenuTitlePerMode") {
        let a = IPAnswer(ip: "185.12.40.7", country: "NL")
        expectEqual(Format.menuTitle(.ip, confirmed: a), "🇳🇱 185.12.40.7")
        expectEqual(Format.menuTitle(.country, confirmed: a), "🇳🇱 NL")
        expectEqual(Format.menuTitle(.icon, confirmed: a), nil)
        expectEqual(Format.menuTitle(.ip, confirmed: nil), "—")
    }

    test("testCountdownFormat") {
        expectEqual(Format.countdown(75), "01:15")
        expectEqual(Format.countdown(-3), "00:00")
        expectEqual(Format.countdown(19.2), "00:20")
        expectEqual(Format.countdown(3723), "1:02:03")
    }

    test("testStateSymbols") {
        expectEqual(Format.stateSymbol(.ok), "checkmark.shield")
        expectEqual(Format.stateSymbol(.frozen(since: Date(), reason: .unconfirmed, deadline: nil)), "exclamationmark.shield")
        expectEqual(Format.stateSymbol(.closed(Date())), "xmark.shield")
        expectEqual(Format.stateSymbol(.paused(until: Date())), "pause.circle")
    }

    test("testTestModeParsing") {
        expectEqual(TestMode.from(environment: ["SAFENET_FAKE_IP": "1.2.3.4,ru"]),
                    TestMode(fakeAnswer: IPAnswer(ip: "1.2.3.4", country: "RU"), offline: false))
        expectEqual(TestMode.from(environment: ["SAFENET_FAKE_IP": "nonsense"]), nil)
        expectEqual(TestMode.from(environment: ["SAFENET_FAKE_IP": "1.2.3.4,RUS"]), nil)
        expectEqual(TestMode.from(environment: [:]), nil)
        expectEqual(TestMode.from(environment: ["SAFENET_FAKE_OFFLINE": "1"]), TestMode(fakeAnswer: nil, offline: true))
    }

    test("testConfigDirOverride") {
        let p = AppPaths.from(environment: ["SAFENET_CONFIG_DIR": "/tmp/sn-test"])
        expectEqual(p.config.path, "/tmp/sn-test/config.yaml")
        expectEqual(p.journal.path, "/tmp/sn-test/frozen.json")
        let d = AppPaths.from(environment: [:])
        expect(d.config.path.hasSuffix("Library/Application Support/SafeNet/config.yaml"), d.config.path)
    }

    test("testNoticeTracker") {
        var t = NoticeTracker()
        let now = Date()
        expectEqual(t.update(.frozen(since: now, reason: .networkChanged, deadline: nil)), nil, "precautionary freeze is silent")
        expectEqual(t.update(.ok), nil, "nothing announced, nothing restored")
        expectEqual(t.update(.frozen(since: now, reason: .countryNotAllowed, deadline: nil))?.body,
                    "Приложения заморожены: страна не разрешена")
        expectEqual(t.update(.frozen(since: now, reason: .unconfirmed, deadline: nil)), nil, "once per episode")
        expectEqual(t.update(.closed(now))?.body, "Приложения закрыты")
        expectEqual(t.update(.ok)?.body, "Защита восстановлена")
        expectEqual(t.update(.paused(until: now)), nil)
        expectEqual(t.update(.ok)?.body, "Защита восстановлена", "end of pause")
        let n = t.update(.frozen(since: now, reason: .ipNotAllowed, deadline: nil))
        expect(!(n?.body.contains("1.2.3.4") ?? true), "no IPs in notifications")
    }

    test("testNotifierWithoutBundleDoesNotCrash") {
        Notifier(bundleIdentifier: nil).post(NoticeText(title: "t", body: "b"))
    }
}
