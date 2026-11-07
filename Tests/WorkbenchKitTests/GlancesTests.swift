import Foundation
import Testing
import WorkbenchKit

/// A finished agent on screen for a second counts as read, once; one passed by, a question, or a window in the
/// background doesn't; one that finishes unread again later is read again.
@Test func aGlanceOfASecondMarksAFinishedAgentReadOnce() {
    var g = Glances(), unread: Set<String> = ["a", "b"]
    let readable: (String) -> Bool = { $0 == "a" }   // b is asking: not read by a glance
    let t0 = Date()
    func tick(_ s: Double, front: Bool = true, shown: [String] = ["a", "b"]) -> [String] {
        g.tick(
            front: front, shown: shown, readable: { readable($0) && unread.contains($0) },
            unread: { unread.contains($0) }, now: t0.addingTimeInterval(s))
    }
    #expect(tick(0) == [])
    #expect(tick(0.5) == [])
    #expect(tick(1) == ["a"])
    #expect(tick(2) == [] && tick(3) == [])   // asked once, while the record still says unread
    unread.remove("a")
    #expect(tick(4) == [])
    unread.insert("a")   // finished unread again
    #expect(tick(5) == [] && tick(6) == ["a"])
    g.failed("a")
    #expect(tick(6.5) == [] && tick(7.5) == ["a"])   // the ask failed: asked again
    unread = ["a"]
    g = Glances()
    #expect(tick(0, front: false) == [] && tick(5, front: false) == [])   // never in front
    #expect(tick(10) == [] && tick(10.5, shown: []) == [] && tick(11) == [] && tick(12) == ["a"])   // passed by: the second starts over
}
