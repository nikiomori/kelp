import AppKit
import Core
import Foundation
import Testing

@testable import KelpKit

@MainActor private final class StandIn: DrivenPage {
    var held: Bool?
    func picture() async -> NSImage? { nil }
    func bringForward() {}
    func hold(_ user: Bool) { held = user }
}

/// An agent's page marks its row: lit after an action, in the agent's colour; grey once that's past; the user's when
/// they take it; gone with the page. A subagent's lights its dot and its tab.
@MainActor @Test func aDrivenPageMarksItsAgentsRowAndTab() async throws {
    let pages = AgentPages(app: AppModel()), page = StandIn()
    #expect(pages.mark(for: "s1") == nil)
    var own = AgentPages.Page(session: "s1", subagent: nil, workspace: "w", tab: "t1")
    own.color = .systemOrange
    pages.drives("p1", own, handle: page)
    #expect(pages.mark(for: "s1") == .init(color: nil, holder: .agent))   // open, not acting: grey
    pages.acted("p1", "clicks “Pay now”")
    #expect(pages.mark(for: "s1") == .init(color: .systemOrange, holder: .agent))
    #expect(pages.glow(tab: "t1") == .systemOrange)
    #expect(pages.litSubagents(of: "s1").isEmpty)

    var mobile = AgentPages.Page(session: "s1", subagent: "a1", workspace: "w", tab: "t1")
    mobile.color = .systemOrange
    pages.drives("p2", mobile, handle: page)
    for step in ["one", "two", "three", "four"] { pages.acted("p2", step) }
    #expect(pages.pages["p2"]?.steps.map(\.text) == ["two", "three", "four"])   // the last few
    #expect(pages.litSubagents(of: "s1") == ["a1"])
    #expect(pages.of(session: "s1").map(\.id) == ["p1", "p2"])   // its own page first

    pages.change("p1") { $0.holder = .user }
    #expect(pages.mark(for: "s1")?.holder == .user)
    pages.handle("p1")?.hold(false)
    #expect(page.held == false)

    pages.closed("p1")
    pages.closed("p2")
    #expect(pages.mark(for: "s1") == nil)
    #expect(pages.glow(tab: "t1") == nil)
}

@MainActor @Test func aSubagentOnAPageHasALitDot() {
    let a = Subagent(id: "a", kind: "", task: nil), b = Subagent(id: "b", kind: "", task: nil)
    #expect(ChildrenBadge.marks(kids: [], running: [a, b], finished: [], browsing: ["b"]).pips == [.browses, .works])
}
