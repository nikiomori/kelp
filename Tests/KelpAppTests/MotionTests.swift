import AppKit
import Testing
@testable import DesignKit

/// A press takes 4 pt off a long control and at most a tenth off a small one, or a bar under a terminal shrinks by 90 pt.
@MainActor @Test func aPressDipsByPointsNotByShare() {
    func taken(_ w: CGFloat, _ h: CGFloat = 24) -> CGFloat { (1 - Motion.pressDip(CGSize(width: w, height: h))) * max(w, h) }
    #expect(abs(taken(22, 22) - 2.2) < 0.01)
    #expect(abs(taken(180) - 4) < 0.01)
    #expect(abs(taken(900) - 4) < 0.01)
}

/// Rings and glows started at different moments still keep step: each starts on the clock's beat, already past.
@MainActor @Test func endlessMotionStartsOnTheBeat() {
    let start = Motion.beat(2.4)
    #expect(start <= CACurrentMediaTime())
    #expect(abs(remainder(start, 2.4)) < 0.001)   // rounding can leave it just under a multiple
}
