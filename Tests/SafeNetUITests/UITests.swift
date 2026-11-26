import CoreGraphics
import SafeNetCore
@testable import SafeNetUI

func registerUITests() {
    test("testUIModuleLinks") {
        expectEqual(Metrics.hairlineWidth, 1)
    }

    test("testQuorumSettingsCountCloudflareAmongIPv4Services") {
        expectEqual(IPServiceSet.ipv4Hosts.count, 5)
        expect(IPServiceSet.ipv4Hosts.contains("www.cloudflare.com"))
        expect(!IPServiceSet.ipv4Hosts.contains("1.1.1.1"))
    }
}

func registerMenuAnchorTests() {
    // A 1440×900 notch screen: menu bar 870…900.
    let screen = (frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visible: CGRect(x: 0, y: 0, width: 1440, height: 870))

    test("testMenuWindowPinnedUnderMenuBar") {
        // Opened far below the bar (status item in a menu-bar manager's strip).
        let low = CGRect(x: 600, y: 520, width: 300, height: 260)
        let f = MenuWindowAnchor.frame(for: low, screens: [screen])!
        expectEqual(f.maxY, 868, "top 2 pt under the menu bar")
        expectEqual(f.size, low.size); expectEqual(f.minX, 600, "x kept when on screen")
        // Hidden status item above the screen (frame seen in a debug run).
        let high = CGRect(x: 436, y: 707, width: 300, height: 223)
        expectEqual(MenuWindowAnchor.frame(for: high, screens: [screen])!.maxY, 868)
        // Already right: unchanged.
        let ok = CGRect(x: 436, y: 868 - 223, width: 300, height: 223)
        expectEqual(MenuWindowAnchor.frame(for: ok, screens: [screen]), ok)
    }

    test("testMenuWindowKeptOnScreenAndPerScreen") {
        let right = CGRect(x: 1300, y: 600, width: 300, height: 200)
        expectEqual(MenuWindowAnchor.frame(for: right, screens: [screen])!.maxX, 1436, "pulled back inside")
        let second = (frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), visible: CGRect(x: 1440, y: 0, width: 1920, height: 1055))
        let onSecond = CGRect(x: 2000, y: 300, width: 300, height: 200)
        expectEqual(MenuWindowAnchor.frame(for: onSecond, screens: [screen, second])!.maxY, 1053, "its own screen's bar")
        let autoHide = (frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visible: CGRect(x: 0, y: 0, width: 1440, height: 900))
        expectEqual(MenuWindowAnchor.frame(for: right, screens: [autoHide])!.maxY, 874, "auto-hidden bar: below its height")
        expect(MenuWindowAnchor.frame(for: right, screens: []) == nil)
    }
}
