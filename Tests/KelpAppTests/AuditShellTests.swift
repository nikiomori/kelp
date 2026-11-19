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

/// The branch chip's glyph stays where a plain title leaves it, in the slot the CI mark is drawn over, so the mark never
/// covers the branch's name. Drawn, because the cell's own rects don't follow a title that hugs its image.
@MainActor @Test func theBranchChipsGlyphStaysInTheSlotTheCIMarkCovers() throws {
    let chip = WindowBar.chip("arrow.triangle.branch")
    func inkStarts(_ title: NSAttributedString) throws -> CGFloat {
        chip.attributedTitle = title
        chip.frame = NSRect(origin: .zero, size: chip.fittingSize)
        let rep = try #require(chip.bitmapImageRepForCachingDisplay(in: chip.bounds))
        chip.cacheDisplay(in: chip.bounds, to: rep)
        let first = (0..<rep.pixelsWide).first { x in
            (0..<rep.pixelsHigh).contains { y in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 }
        }
        return CGFloat(try #require(first)) * chip.bounds.width / CGFloat(rep.pixelsWide)
    }
    for name in ["main", "feature/a-much-longer-branch-name"] {
        let words: [NSAttributedString.Key: Any] = [.font: NSFont.ui(TextSize.row), .foregroundColor: NSColor.black]
        let plain = try inkStarts(NSAttributedString(string: name, attributes: words))
        let cut = try inkStarts(WindowBar.cutInMiddle(NSMutableAttributedString(string: name, attributes: words)))
        #expect(abs(cut - plain) < 0.6, "\(name): the glyph starts at \(cut), a plain title's at \(plain)")
    }
}
