@testable import SafeNetUI

func registerUITests() {
    test("testUIModuleLinks") {
        expectEqual(SafeNetUIInfo.moduleName, "SafeNetUI")
    }
}
