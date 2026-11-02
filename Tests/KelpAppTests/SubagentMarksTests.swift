import Core
import Foundation
import Testing
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

@MainActor @Test func aDotStandsForEachSubagentOfTheTurn() {
    #expect(marks().pips.isEmpty)
    #expect(marks(running: [run("a"), run("b")]).pips == [.works, .works])
    #expect(marks(running: [run("a"), run("b")], finished: [run("c"), run("d")]).pips == [.works, .works, .finished, .finished])
    #expect(marks(running: [run("a"), run("b", asks: true)]).pips == [.asks, .works])
}

@MainActor @Test func finishedSubagentsLeaveWithTheLastOneAtWork() {
    #expect(marks(finished: [run("a"), run("b")]).pips.isEmpty)
}

@MainActor @Test func aStartedAgentStaysOnceItFinished() {
    #expect(marks(kids: [kid(.done)]).pips == [.finished])
    #expect(marks(kids: [kid(.error), kid(.working)]).pips == [.failed, .works])
}

@MainActor @Test func pastFourADotAndHowManyAreAtWork() {
    let four = marks(running: [run("a"), run("b"), run("c"), run("d")])
    #expect(four.pips.count == 4 && four.count == nil)
    let seven = marks(running: (1...6).map { run("\($0)") } + [run("x", asks: true)], finished: [run("f")])
    #expect(seven.pips == [.asks] && seven.count == 7)
    let done = marks(kids: (1...5).map { _ in kid(.done) })
    #expect(done.pips == [.finished] && done.count == 5)
}

@Test func aKindIsShownWhenItSaysSomething() {
    #expect(Subagent(id: "a", kind: "general-purpose", task: "Reviews").shownKind == nil)
    #expect(Subagent(id: "a", kind: "Explore", task: "Reviews").shownKind == "Explore")
    #expect(Subagent(id: "a", kind: "Explore", task: nil).shownKind == nil)
    #expect(Subagent(id: "a", kind: "Explore", task: nil).title == "Explore")
}
