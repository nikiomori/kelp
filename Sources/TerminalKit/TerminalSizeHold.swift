import AppKit

extension GhosttyTerminalView {
    /// A panel slides beside the terminals: each stays at its size until `false`, then takes its new one once and without
    /// the "120 × 40" badge, which is for someone resizing by hand. Nested holds count.
    public static func holdSize(_ on: Bool) {
        holds = max(0, holds + (on ? 1 : -1))
        guard !on, holds == 0 else { return }
        NotificationCenter.default.post(name: sizeReleased, object: nil)
    }
    static var holds = 0
    static let sizeReleased = Notification.Name("GhosttyTerminalView.sizeReleased")

    @objc func takeSize() {
        updateSize()
        shownGrid = gridSize
    }
}
