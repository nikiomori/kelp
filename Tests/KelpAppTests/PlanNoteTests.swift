import Foundation
import Testing
@testable import KelpKit

private func note(_ used: Double, resets: String? = "3:40pm", read: Date? = nil) -> PlanNote? {
    PlanNote(fullest: (label: "Week", used: used, resets: resets), readAt: read)
}

@Test func aPlansNoteSaysHowFullItIsAndUntilWhen() {
    #expect(note(0.92)?.text == "92 % · 3:40pm")
    #expect(note(0.12, resets: nil)?.text == "12 %")
    #expect(note(1)?.text == "Full · 3:40pm")
}

@Test func anUnusedOrOldPlanSaysNothing() {
    #expect(note(0) == nil)
    #expect(note(0.5, read: Date().addingTimeInterval(-2000)) == nil)
    #expect(note(0.5, read: Date().addingTimeInterval(-60)) != nil)
    #expect(PlanNote(fullest: nil, readAt: nil) == nil)
}

@Test func onlyANearlyFullPlanWarns() {
    #expect(note(0.89)?.warning(for: "Claude") == nil)
    #expect(note(0.92)?.warning(for: "Claude") == "Claude is at 92 % until 3:40pm.")
    #expect(note(1, resets: nil)?.warning(for: "Claude") == "Claude is full.")
}

@Test func theOtherAgentOfferedHasTheMostLeft() throws {
    let low = try #require(note(0.12)), mid = try #require(note(0.4)), high = try #require(note(0.6))
    #expect(PlanNote.roomiest(["a", "b"], notes: ["a": mid, "b": low]) == "b")
    #expect(PlanNote.roomiest(["a"], notes: ["a": high]) == nil)    // not much better
    #expect(PlanNote.roomiest(["c"], notes: [:]) == nil)            // no reading, no promise
}
