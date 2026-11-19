import AppKit
import Testing

@testable import DesignKit

/// Kelp's segmented choice: each segment as wide as its word (choosing one doesn't move the others), a choice by the
/// pointer, the arrows or VoiceOver sends the action once, a switched-off segment can't be chosen, and the control grows
/// with Text size.
@MainActor @Test func aCapsuleChoiceSizesByItsWordsAndChoosesOnce() throws {
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

    let normal = control.intrinsicContentSize
    TextSize.apply("larger")
    defer { TextSize.apply(nil) }
    #expect(control.intrinsicContentSize.height > normal.height && control.intrinsicContentSize.width > normal.width)
}
