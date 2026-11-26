import SwiftUI
import AppKit

/// Keeps the menu-bar window right under the menu bar.
///
/// `MenuBarExtra` hangs its window under wherever the status item happens to be. On a crowded
/// menu bar (notch Macs, menu-bar managers) the item can sit outside the bar: hidden above the
/// screen, or in a manager's strip below it. The window then opens far off. This view (placed in
/// the window's content) pins the window's top to the bottom of the menu bar and keeps it on the
/// screen, every time the window is shown, moved or resized.
struct MenuWindowAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ v: AnchorView, context: Context) { v.pin() }

    final class AnchorView: NSView {
        private var observers: [NSObjectProtocol] = []
        private var pinning = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            guard let w = window else { return }
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                                              NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification,
                                              NSWindow.didChangeScreenNotification]
            for n in names {
                observers.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] _ in
                    self?.pin()
                })
            }
            DispatchQueue.main.async { [weak self] in self?.pin() }
        }

        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

        func pin() {
            guard !pinning, let w = window, w.isVisible, w.frame.height > 0 else { return }
            guard let target = MenuWindowAnchor.frame(for: w.frame, screens: NSScreen.screens.map { ($0.frame, $0.visibleFrame) })
            else { return }
            guard abs(target.origin.y - w.frame.origin.y) > 0.5 || abs(target.origin.x - w.frame.origin.x) > 0.5 else { return }
            pinning = true
            NSLog("SafeNet: menu window moved from %@ to %@", NSStringFromRect(w.frame), NSStringFromRect(target))
            w.setFrameOrigin(target.origin)
            pinning = false
        }
    }

    /// Gap the system leaves between the menu bar and a menu-bar window.
    static let gap: CGFloat = 2

    /// Where the window belongs: the screen under its horizontal centre (else the first one),
    /// top `gap` below the menu bar, fully on that screen horizontally. nil = no screen known.
    /// Pure (screens as (frame, visibleFrame) pairs, AppKit coordinates, y up) for tests.
    static func frame(for f: CGRect, screens: [(frame: CGRect, visible: CGRect)]) -> CGRect? {
        guard let s = screens.first(where: { $0.frame.minX <= f.midX && f.midX < $0.frame.maxX }) ?? screens.first
        else { return nil }
        // With an auto-hidden menu bar the visible frame reaches the screen top: keep the system's
        // own bar height (~24 pt) below the top so the window is not glued to the edge.
        let barBottom = s.visible.maxY < s.frame.maxY ? s.visible.maxY : s.frame.maxY - 24
        var out = f
        out.origin.y = barBottom - gap - f.height
        out.origin.x = min(max(f.minX, s.visible.minX + 4), s.visible.maxX - f.width - 4)
        return out
    }
}
