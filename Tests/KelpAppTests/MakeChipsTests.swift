import AppKit
import DesignKit
import Testing

@testable import KelpKit

extension OneAtATime {
    /// Make's chips at the foot of the start page's field: each keeps its whole width, a gap from the next, and stays as
    /// far in from the field's edges as the text above. A row takes the chips that fit, in order, the rest wrap onto
    /// the next row a gap below, and the field grows to hold them. At the start page's width, a narrower one, Larger
    /// text, and a wide field where one row holds them all.
    @Test(
        arguments: [(nil, 460, false), (nil, 300, false), ("larger", 460, false), (nil, 1000, true)]
            as [(String?, CGFloat, Bool)])
    func makeChipsWrapInsideTheField(textSize: String?, width: CGFloat, oneRow: Bool) {
        TextSize.apply(textSize)
        defer { TextSize.apply(nil) }
        let make = MakeChips { _ in }
        let field = StartView.field(NSView(), make)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        field.layoutSubtreeIfNeeded()
        let frames = make.chips.map { field.convert($0.frame, from: make) }
        let right = width - Metrics.inset
        for (chip, frame) in zip(make.chips, frames) {
            #expect(frame.width == chip.intrinsicContentSize.width, "\(chip.title)")
            #expect(frame.minX >= Metrics.inset && frame.maxX <= right, "\(chip.title) at \(frame)")
        }
        // In the chips' own place, top down.
        let placed = make.chips.map(\.frame)
        for (before, after) in zip(placed, placed.dropFirst()) {
            if after.minY == before.minY {
                #expect(after.minX == before.maxX + Metrics.gap)
            } else {   // a new row: the chip wouldn't have fit after the one before
                #expect(after.minX == 0 && after.minY == before.maxY + Metrics.gap)
                #expect(before.maxX + Metrics.gap + after.width > make.bounds.width)
            }
        }
        #expect((Set(placed.map(\.minY)).count == 1) == oneRow)
        let foot = field.convert(make.bounds, from: make)
        #expect(frames.allSatisfy { foot.contains($0) } && field.bounds.contains(foot))
    }
}
