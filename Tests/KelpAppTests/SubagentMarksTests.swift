import AppKit
import Core
import Foundation
import Testing
import WorkbenchKit

@testable import KelpKit

private func run(_ id: String, asks: Bool = false) -> Subagent {
    var s = Subagent(id: id, kind: "", task: nil)
    s.asks = asks ? true : nil
    return s
}

private func kid(_ status: AgentStatus) -> Session {
    var s = Session(cwd: "/", command: "claude")
    s.status = status
    return s
}

private typealias Marks = (pips: [ChildrenBadge.Pip], count: Int?)
@MainActor private func marks(kids: [Session] = [], running: [Subagent] = [], finished: [Subagent] = []) -> Marks {
    ChildrenBadge.marks(kids: kids, running: running, finished: finished)
}

/// A dot for each subagent of the turn, asking first; finished ones leave with the last one at work; a started agent
/// stays once it finished; past four, one dot and how many are at work.
@MainActor @Test func aRowsDotsStandForItsSubagentsAndAgents() {
    let cases: [(marks: Marks, pips: [ChildrenBadge.Pip], count: Int?)] = [
        (marks(), [], nil),
        (marks(running: [run("a"), run("b")]), [.works, .works], nil),
        (
            marks(running: [run("a"), run("b")], finished: [run("c"), run("d")]),
            [.works, .works, .finished, .finished], nil
        ),
        (marks(running: [run("a"), run("b", asks: true)]), [.asks, .works], nil),
        (marks(finished: [run("a"), run("b")]), [], nil),
        (marks(kids: [kid(.done)]), [.finished], nil),
        (marks(kids: [kid(.error), kid(.working)]), [.failed, .works], nil),
        (marks(running: [run("a"), run("b"), run("c"), run("d")]), [.works, .works, .works, .works], nil),
        (marks(running: (1...6).map { run("\($0)") } + [run("x", asks: true)], finished: [run("f")]), [.asks], 7),
        (marks(kids: (1...5).map { _ in kid(.done) }), [.finished], 5)
    ]
    for (number, c) in cases.enumerated() {
        #expect(c.marks.pips == c.pips && c.marks.count == c.count, "case \(number)")
    }
}

/// Three or four dots stand two to a line, so they take the width of two and leave it to the name.
@MainActor @Test func dotsStandTwoToALine() {
    #expect(
        PipsView.grid(0) == (0, 0) && PipsView.grid(2) == (2, 1) && PipsView.grid(3) == (2, 2)
            && PipsView.grid(4) == (2, 2))
    #expect((0..<2).map { PipsView.cell($0, of: 2) }.map { [$0.column, $0.line] } == [[0, 0], [1, 0]])
    #expect(
        (0..<4).map { PipsView.cell($0, of: 4) }.map { [$0.column, $0.line] } == [[0, 0], [1, 0], [0, 1], [1, 1]])
    let view = PipsView()
    view.pips = [.works, .works, .finished, .finished]
    #expect(view.intrinsicContentSize == NSSize(width: 12, height: 12))
}

@Test func aKindIsShownWhenItSaysSomething() {
    #expect(Subagent(id: "a", kind: "general-purpose", task: "Reviews").shownKind == nil)
    #expect(Subagent(id: "a", kind: "Explore", task: "Reviews").shownKind == "Explore")
    #expect(Subagent(id: "a", kind: "Explore", task: nil).shownKind == nil)
    #expect(Subagent(id: "a", kind: "Explore", task: nil).title == "Explore")
}

/// A click on the dots doesn't wait out the half second a resting pointer does.
@MainActor @Test func aRowsCardOpensAtOnceWhenAsked() async throws {
    let rig = try await AppRig()
    defer { rig.done() }
    let vc = NSViewController()
    vc.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    rig.show(vc, 200, 200)
    let card = HoverCard(app: rig.app)
    card.open(.project(rig.project.id), rect: NSRect(x: 0, y: 0, width: 200, height: 24), in: vc.view)
    #expect(card.shownKind == .project(rig.project.id))
    card.close()
    #expect(card.shownKind == nil)
}
