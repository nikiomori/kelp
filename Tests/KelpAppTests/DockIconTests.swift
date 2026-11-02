import AppKit
import Core
import Testing
@testable import KelpKit

private func session(_ status: AgentStatus, unread: Bool = false, parent: String? = nil, agent: String = "claude") -> Session {
    var s = Session(cwd: "/", command: "x", agent: agent, status: status, unread: unread)
    s.parent = parent
    return s
}

@MainActor @Test func theDockIconPutsWhatWantsYouFirst() {
    let cells = DockIcon.cells([session(.working), session(.done, unread: true), session(.error), session(.waiting)])
    #expect(cells == [.asks, .failed, .working, .done])
}

@MainActor @Test func theDockIconLeavesOutWhatNeedsNothing() {
    #expect(DockIcon.cells([session(.idle), session(.exited), session(.done), session(.hibernated)]).isEmpty)   // done and read
    #expect(DockIcon.cells([session(.done, unread: true, parent: "p")]).isEmpty)   // its result goes to its parent
    #expect(DockIcon.cells([session(.working, agent: "shell")]).isEmpty)   // a terminal, not a chat
    #expect(DockIcon.cells([session(.hibernated, unread: true)]) == [.done])   // paused with a result you haven't read
}

@MainActor @Test func aDockIconWithTooManyAgentsKeepsTheOnesThatWantYou() {
    let cells = DockIcon.cells(Array(repeating: session(.working), count: 12) + [session(.waiting)])
    #expect(cells.count == DockFace.cells)
    #expect(cells.first == .asks)
}

@MainActor @Test func thePlanOnTheDockIconTurnsAtTheWarningLevel() {
    #expect(DockIcon.usage(79.6, warnAt: 80) == .usage(percent: 80, high: false))   // reads 80, is under it
    #expect(DockIcon.usage(80, warnAt: 80) == .usage(percent: 80, high: true))
    #expect(DockIcon.usage(99, warnAt: nil) == .usage(percent: 99, high: false))   // warnings are off
}
