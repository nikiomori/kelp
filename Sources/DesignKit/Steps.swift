import AppKit

extension NSSegmentedControl {
    /// ↑ ↓ to step through matches or changes, as the system's find bar has them: two small separated segments, the
    /// tooltips naming each with its key. The action reads `selectedSegment`: 0 is previous, 1 next.
    public static func steps(previous: String, next: String, target: AnyObject, action: Selector) -> NSSegmentedControl {
        let up = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: previous) ?? NSImage()
        let down = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: next) ?? NSImage()
        let s = NSSegmentedControl(images: [up, down], trackingMode: .momentary, target: target, action: action)
        s.controlSize = .small
        s.segmentStyle = .separated
        s.setToolTip(previous, forSegment: 0)
        s.setToolTip(next, forSegment: 1)
        return s
    }
}
