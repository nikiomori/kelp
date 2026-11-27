import AppKit
import Core
import Foundation
import Testing
import WorkbenchKit

@testable import BuiltinBrowser
@testable import KelpKit

/// An agent's page marks its row: lit after an action, in the agent's colour; grey once that's past; the user's when
/// they take it; gone with the page. A subagent's lights its dot and its tab.
@MainActor @Test func aDrivenPageMarksItsAgentsRowAndTab() async throws {
    let app = AppModel(), pages = AgentPages(app: app),
        page = BrowserTab(uri: TabURI.agentPage("about:blank"), app: app)
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
    #expect(pages.handle("p1") === page)

    pages.closed("p1")
    pages.closed("p2")
    #expect(pages.mark(for: "s1") == nil)
    #expect(pages.glow(tab: "t1") == nil)
}

@MainActor @Test func aSubagentOnAPageHasALitDot() {
    let a = Subagent(id: "a", kind: "", task: nil), b = Subagent(id: "b", kind: "", task: nil)
    #expect(ChildrenBadge.marks(kids: [], running: [a, b], finished: [], browsing: ["b"]).pips == [.browses, .works])
}

/// The browser's mark on an agent's row, through the shell's one kind of row mark: grey while the page is only open,
/// lit in the agent's colour after an action, its subagents' dots lit too; the accent colour once the user has it.
@MainActor @Test func aDrivenPagesRowMarkSaysWhoHasIt() throws {
    let app = AppModel(), pages = AgentPages.of(app), tab = BrowserTab(uri: TabURI.agentPage("about:blank"), app: app)
    #expect(BrowserMarks.row(.agent("s1"), app).isEmpty)
    var own = AgentPages.Page(session: "s1", subagent: nil, workspace: "w", tab: "t1")
    own.color = .systemOrange
    own.title = "Checkout"
    pages.drives("p1", own, handle: tab)
    var mark: RowMark? = try #require(BrowserMarks.row(.agent("s1"), app).first)
    #expect(mark?.place == .button && mark?.glow == nil && mark?.tip == "Its page: Checkout")
    var sub = AgentPages.Page(session: "s1", subagent: "a1", workspace: "w", tab: "t1")
    sub.color = .systemOrange
    pages.drives("p2", sub, handle: tab)
    pages.acted("p2", "clicks")
    mark = BrowserMarks.row(.agent("s1"), app).first
    #expect(mark?.glow == .systemOrange && mark?.lights == ["a1"] && mark?.tip == "Working in its page: Checkout")
    #expect(BrowserMarks.driven("w", app)["t1"]?.glow == .systemOrange)
    pages.change("p1") { $0.holder = .user }
    mark = BrowserMarks.row(.agent("s1"), app).first
    // Holding the page is grey (nothing waits); a question on it is the one orange: it waits for you.
    #expect(mark?.tint == .secondaryLabelColor && mark?.glow == nil && mark?.tip == "You have its page: Checkout")
    pages.change("p1") { $0.holder = .asked("Pay?") }
    mark = BrowserMarks.row(.agent("s1"), app).first
    #expect(mark?.tint == .textOrange && mark?.tip == "It asks you on its page: Checkout")
    #expect(BrowserMarks.row(.workspace("w"), app).isEmpty)
}

/// A page an agent drives with the user's login says so outside it: the row's mark in the user's own colour, and the
/// tab a person after its title (`TabStrip.Item.trailing`). Its own page says neither.
@MainActor @Test func aPageWithTheUsersLoginIsMarkedOnItsRowAndTab() throws {
    let app = AppModel(), pages = AgentPages.of(app), tab = BrowserTab(uri: "https://x.com/home", app: app)
    var page = AgentPages.Page(session: "s1", subagent: nil, workspace: "w", tab: "t1")
    page.title = "Home / X"
    pages.drives("p1", page, handle: tab)
    #expect(BrowserMarks.driven("w", app)["t1"]?.login == false)
    #expect(try #require(BrowserMarks.row(.agent("s1"), app).first).tint == .secondaryLabelColor)
    pages.change("p1") { $0.login = "x.com" }
    let mark = try #require(BrowserMarks.row(.agent("s1"), app).first)
    #expect(mark.tint == .themeAccent && mark.tip == "Its page, with your login on x.com: Home / X")
    #expect(BrowserMarks.driven("w", app)["t1"]?.login == true)
}

/// A chat's browser skill line is read back by its enums, not its English: a reason in the app's words, the web app
/// found as it is, anything else left alone.
@Test func aBrowserSkillLineIsReadByItsReason() {
    #expect(BrowserSkill.parse("off · no web app found")?.reason == .noWebApp)
    #expect(BrowserSkill.parse("on · Vite in package.json")?.framework == "Vite in package.json")
    for reason in BrowserSkill.Reason.allCases {
        #expect(BrowserSkill.parse(BrowserSkill(on: true, reason).line)?.reason == reason)
        #expect(
            BrowserSkillWords.line(BrowserSkill(on: true, reason).line) == "on · " + BrowserSkillWords.words(reason))
    }
    #expect(BrowserSkillWords.line("on · Vite in package.json") == "on · Vite in package.json")
    #expect(BrowserSkillWords.line("something else") == "something else")
}
