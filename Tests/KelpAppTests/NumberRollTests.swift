import AppKit
import Testing

@testable import DesignKit
@testable import KelpKit

@MainActor private func digits(in view: NSView) -> [NSTextField] {
    view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? digits(in: $0) }
}

/// A panel's count rolls to its new number; the capsule under it stays put.
@MainActor @Test func aPanelsCountRollsOverItsCapsule() {
    let badge = CountBadge()
    let window = onScreen(badge)
    defer { offScreen(window) }
    badge.badge = PanelBadge("3")
    badge.layoutSubtreeIfNeeded()
    badge.badge = PanelBadge("4")
    #expect(digits(in: badge).first?.layer?.animation(forKey: "roll") != nil)
    #expect(badge.layer?.animation(forKey: "roll") == nil)
}

/// The count beside an agent's symbol rolls; one coming from nothing just shows.
@MainActor @Test func aChipsCountRolls() {
    let chip = Chip()
    let window = onScreen(chip)
    defer { offScreen(window) }
    chip.show("terminal", count: 2)
    chip.layoutSubtreeIfNeeded()
    let count = digits(in: chip).first
    #expect(count?.layer?.animation(forKey: "roll") == nil)
    chip.show("terminal", count: 3)
    #expect(count?.layer?.animation(forKey: "roll") != nil)
}

extension OneAtATime {
    /// A count keeps its width when its digits change, in a look's own typeface too (a serif "1" is narrower than its "0").
    @Test func digitsAreOneWidthInALooksTypeface() {
        defer { TextSize.apply(design: nil) }
        for design in ["serif", "rounded", "mono", nil] {
            TextSize.apply(design: design)
            let font = NSFont.uiDigits(TextSize.caption)
            func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
            #expect(width("111") == width("000"), "\(design ?? "system")")
        }
    }
}
