import AppKit

extension NSSegmentedControl {
    /// ↑ ↓ to step through matches or changes, as the system's find bar has them: two small separated segments, with
    /// tooltips naming each with its key. The action reads `selectedSegment`, where 0 is previous and 1 next.
    public static func steps(previous: String, next: String, target: AnyObject, action: Selector) -> NSSegmentedControl
    {
        // Medium, as every symbol in the chrome is (`.chrome`): the segments' own regular read as a hairline.
        let up = NSImage.symbol("chevron.up", previous).withSymbolConfiguration(.chrome(Metrics.iconSmall)) ?? NSImage()
        let down = NSImage.symbol("chevron.down", next).withSymbolConfiguration(.chrome(Metrics.iconSmall)) ?? NSImage()
        let control = NSSegmentedControl(images: [up, down], trackingMode: .momentary, target: target, action: action)
        control.controlSize = .small
        control.segmentStyle = .separated
        control.setToolTip(previous, forSegment: 0)
        control.setToolTip(next, forSegment: 1)
        return control
    }
}
