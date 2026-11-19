import AppKit
import Testing

@testable import DesignKit

extension OneAtATime {
    /// Kelp's segmented choice: each segment as wide as its word (choosing one doesn't move the others), a choice by the
    /// pointer, the arrows or VoiceOver sends the action once, a switched-off segment can't be chosen, and the control grows
    /// with Text size.
    @Test func aCapsuleChoiceSizesByItsWordsAndChoosesOnce() throws {
        @MainActor final class Sink: NSObject {
            var sent: [Int] = []
            @objc func changed(_ control: CapsuleSegments) { sent.append(control.selectedSegment) }
        }
        let sink = Sink()
        let control = CapsuleSegments(
            labels: ["7 Days", "30 Days", "90 Days"], target: sink, action: #selector(Sink.changed))
        control.controlSize = .small
        control.selectedSegment = 1
        control.frame = NSRect(origin: .zero, size: control.intrinsicContentSize)
        let rects = control.segmentRects()
        #expect(rects.count == 3 && rects[0].width < rects[1].width)   // "7 Days" is shorter than "30 Days"
        let chosen = rects.map(\.width)
        control.selectedSegment = 0
        #expect(control.segmentRects().map(\.width) == chosen)
        #expect(sink.sent.isEmpty)   // set by code: no action

        let segments = try #require(control.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(segments.map { $0.accessibilityRole() } == Array(repeating: .radioButton, count: 3))
        #expect(segments[2].accessibilityPerformPress() && control.selectedSegment == 2 && sink.sent == [2])
        control.setEnabled(false, forSegment: 1)
        #expect(segments[1].accessibilityPerformPress() && control.selectedSegment == 2 && sink.sent == [2])
        #expect(control.accessibilityValue() as? String == "90 Days")
        // VoiceOver keeps its cursor on a segment, so each is the same element after a change, its value moved on.
        let again = try #require(control.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(zip(again, segments).allSatisfy { $0 === $1 } && again[2].accessibilityValue() as? Int == 1)
        #expect((control.accessibilitySelectedChildren() as? [NSAccessibilityElement])?.first === segments[2])

        // A tip's own area outlives the pointer's being put back (a scroll calls `updateTrackingAreas`, not `layout`).
        control.setToolTip("Last week", forSegment: 0)
        control.layout()
        control.updateTrackingAreas()
        let areas = control.trackingAreas.count
        control.updateTrackingAreas()
        #expect(areas > 1 && control.trackingAreas.count == areas)

        let normal = control.intrinsicContentSize
        TextSize.apply("larger")
        defer { TextSize.apply(nil) }
        #expect(
            control.intrinsicContentSize.height > normal.height && control.intrinsicContentSize.width > normal.width)
    }
}
