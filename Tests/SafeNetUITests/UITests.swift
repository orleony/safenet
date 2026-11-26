@testable import SafeNetUI

func registerUITests() {
    test("testUIModuleLinks") {
        expectEqual(Metrics.hairlineWidth, 1)
    }

    test("testQuorumSettingsCountCloudflareAmongIPv4Services") {
        expectEqual(SettingsTab.serviceCount, 5)
    }
}
