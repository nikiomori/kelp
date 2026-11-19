import AppKit
import Core
import DesignKit
import Testing

@testable import KelpKit

/// The context pie is grey from its first level and takes colour only when it's time to compact (orange) and just
/// before the agent compacts by itself (red). The hover card's words change at the same tokens, in the text shades.
@MainActor @Test func theContextPieIsGreyUntilItIsTimeToCompact() {
    let level = { (used: Int) in ContextMeter.level(SessionContextWindow.Usage(used: used, window: 200_000)) }
    let rows: [(used: Int, pie: NSColor, words: NSColor)] = [
        (100_000, .secondaryLabelColor, .secondaryLabelColor),
        (130_000, .systemOrange, .textOrange),
        (156_000, .systemRed, .textRed)
    ]
    for row in rows {
        #expect(ContextMeter.color(level(row.used)) == row.pie)
        #expect(ContextMeter.textColor(level(row.used)) == row.words)
    }
}

/// A passed CI run is a grey filled ✓, as the sidebar draws it; only a failure is coloured.
@MainActor @Test func aPassedRunIsGreyAndOnlyAFailureIsColoured() {
    let tint = { (conclusion: String) in (CIRunLook.mark("completed", conclusion) as? NSImageView)?.contentTintColor }
    #expect(tint("success") == .secondaryLabelColor)
    #expect(tint("failure") == .systemRed)
}

/// When two folders change the same files, the changes dot is doubled, not coloured: it's a state, not a call.
@MainActor @Test func sharedChangesAreADoubleGreyDot() {
    for (shared, text) in [(false, "•"), (true, "••")] {
        let dot = SidebarCell.dot(shared: shared)
        #expect(dot.string == text)
        #expect(dot.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .secondaryLabelColor)
    }
}
