import Foundation
import SafeNetCore
@testable import SafeNetUI

private func previewState(_ c: Config = .default, status: EngineStatus = EngineStatus()) -> AppState {
    AppState(preview: c, status: status)
}

func registerAppStateTests() {
    test("testAutostartMessageSurvivesConfigUpdate") {
        let m = previewState()
        m.setAutostart(true)                       // test binary has no bundle id: refused with a message
        expect(m.autostartError != nil, "autostart refused outside a .app")
        var c = Config.default; c.apps = ["claude"]
        m.receiveConfig(c)
        expect(m.autostartError != nil, "a config update must not wipe the autostart message")
        expect(m.messages.contains { $0.text.hasPrefix("Автозапуск") })
    }

    test("testNoticeSurvivesConfigUpdateAndIsNotAnError") {
        let m = previewState()
        m.receiveNotice("Тестовый режим: настройки не сохраняются")
        m.receiveConfig(Config.default)
        expectEqual(m.notice, "Тестовый режим: настройки не сохраняются")
        expectEqual(m.messages.first { $0.text.hasPrefix("Тестовый") }?.isError, false)
    }

    test("testConfigErrorClearedOnlyWhenConfigHealthy") {
        let m = previewState()
        m.receiveConfigError("не удалось сохранить config.yaml (x)")
        m.receiveConfig(Config.default)            // a save failure is followed by the in-memory config
        expect(m.configError != nil, "the save error must stay visible")
        m.configHealthy()
        expectEqual(m.configError, nil)
    }

    test("testPreviewUpdateAppliesConfig") {
        let m = previewState()
        m.update { $0.grace = 42 }
        expectEqual(m.config.grace, 42)
    }

    test("testPauseUsesConfiguredDefault") {
        var c = Config.default; c.pauseDefault = 300
        expectEqual(previewState(c).defaultPause, 300)
    }

    test("testProxyWarningOnlyWithSystemProxy") {
        var s = EngineStatus()
        expectEqual(AppState.proxyWarning(s), nil, "no snapshot: no warning")
        s.snapshot = NetSnapshot(online: true, hasTunnel: true, gatewayIP: nil, gatewayMAC: nil, proxy: nil)
        expectEqual(AppState.proxyWarning(s), nil)
        s.snapshot?.proxy = ProxyInfo(socks: "127.0.0.1:7890")
        expect(AppState.proxyWarning(s)?.contains("TUN") == true)
        expect(previewState(Config.default, status: s).proxyWarning != nil)
    }
    test("testPreviewDeepCheckIsDisabledAndNeverRuns") {
        let m = previewState()
        expect(!m.canDeepCheck)
        m.runDeepCheck()
        expect(!m.deepCheckRunning, "no engine: never stuck in 'running'")
    }
}
