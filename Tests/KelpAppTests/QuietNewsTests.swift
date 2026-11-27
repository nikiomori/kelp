import AppKit
import Core
import Foundation
import Testing
import WorkbenchKit

@testable import KelpKit

/// An agent's news (a few a second while it works) redraws what shows it, not everything that reads the sessions.
/// The probes below are values a redraw would put back: still there, nothing was redrawn.

/// A change reaches a `track` on the next turn of the main queue (`Tracker.run`): after that turn, it had, had it been
/// going to.
@MainActor private func settle() async throws {
    await withCheckedContinuation { turned in DispatchQueue.main.async { turned.resume() } }
}

@MainActor private func find(_ view: NSView, _ match: (NSView) -> Bool) -> NSView? {
    if match(view) { return view }
    for sub in view.subviews { if let hit = find(sub, match) { return hit } }
    return nil
}

/// One tab's news sets only that tab, measures nothing again when no width changed, and scrolls nothing into view.
@MainActor @Test func oneTabsNewsTouchesOnlyItsTab() async throws {
    let strip = TabStrip()
    strip.frame = NSRect(x: 0, y: 0, width: 600, height: 40)
    let one = TabStrip.Item(id: "a", title: "One", toolTip: nil)
    var two = TabStrip.Item(id: "b", title: "Two", toolTip: nil)
    strip.set([one, two], selected: "a")
    strip.layoutSubtreeIfNeeded()
    try await settle()
    #expect(strip.measured != nil && !strip.revealing)
    strip.buttons[0].toolTip = "probe"
    two.badge = TabBadge(status: .working, progress: 0.4)
    strip.set([one, two], selected: "a")
    #expect(strip.buttons[0].toolTip == "probe")   // the other tab wasn't set again
    #expect(strip.buttons[1].item == two)
    #expect(strip.measured != nil)   // a mark in the slot: no tab got wider
    #expect(!strip.revealing)   // same tabs, same one chosen
    two.title = "Two, renamed at length"
    strip.set([one, two], selected: "a")
    #expect(strip.measured == nil)   // a title did change a width
    strip.set([one, two], selected: "b")
    #expect(strip.revealing)
}

/// A tab whose title is observed, as a real tab's is.
@MainActor @Observable private final class TitledTab: TabContent {
    let uri: String
    let view = NSView()
    var title = "One"
    var icon: NSImage? { nil }
    init(_ uri: String) { self.uri = uri }
    func focus() {}
}

extension OneAtATime {
    /// A workspace kept loaded off screen doesn't redraw its tabs at each change: it does when it's back.
    @Test func aWorkspaceOffScreenRedrawsItsTabsWhenBack() async throws {
        _ = testHome
        var made: TitledTab?
        let tabs = Builtin("test.titled", "Titled", "", icon: "doc") { _ in
            Contributions(
                tabs: [
                    TabProvider(schemes: ["titled"]) { uri in
                        let tab = TitledTab(uri)
                        made = tab
                        return tab
                    }
                ])
        }
        let app = AppModel(builtins: [tabs])
        app.extensions.reload()
        var layout = WorkspaceLayout()
        layout.add("titled:x")
        app.workbench.layouts["w"] = layout
        let area = EditorArea(app: app, workspaceId: "w")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
            defer: true)   // never shown
        window.contentView?.addSubview(area.view)
        area.render()
        let tab = try #require(made)
        let strip = try #require(area.groupViews.values.first?.strip)
        #expect(strip.buttons.first?.item?.title == "One")

        area.view.removeFromSuperview()   // another workspace on screen
        tab.title = "Two"
        try await settle()
        #expect(strip.buttons.first?.item?.title == "One")
        #expect(!area.unshown.isEmpty)
        window.contentView?.addSubview(area.view)
        #expect(strip.buttons.first?.item?.title == "Two")   // at once
        #expect(area.unshown.isEmpty)
        tab.title = "Three"
        try await settle()
        #expect(strip.buttons.first?.item?.title == "Three")   // on screen: as it changes
    }

    /// A session's news asks again for the heights of its own rows only; the others keep theirs.
    @Test func anAgentsNewsMeasuresOnlyItsRows() throws {
        var a = Session(
            id: "a", worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: .working, title: "One")
        let b = Session(
            id: "b", worktreeId: "w2", cwd: "/", command: "claude", agent: "claude", status: .working, title: "Two")
        let project = Repo(id: "r1", name: "Atlas", path: "/tmp/kelp-screen-atlas")
        let worktrees = [
            Worktree(id: "w1", repoId: "r1", branch: "one", path: "/tmp/kelp-screen-atlas/w1"),
            Worktree(id: "w2", repoId: "r1", branch: "two", path: "/tmp/kelp-screen-atlas/w2")
        ]
        try withSidebar(repos: [project], worktrees: worktrees, sessions: [a, b]) { vc, o in
            let nodeA = try #require(vc.node("a:a")), nodeB = try #require(vc.node("a:b"))
            let rowA = o.row(forItem: nodeA), rowB = o.row(forItem: nodeB)
            #expect(rowA >= 0 && rowB >= 0 && vc.rowHeights.count == o.numberOfRows)
            vc.rowHeights[rowA] = 999
            vc.rowHeights[rowB] = 999   // a probe: asked again, it would be the row's real height
            a.title = "One, renamed"
            vc.sessionsChanged([a, b])
            #expect(vc.rowHeights[rowA] != 999)
            #expect(vc.rowHeights[rowB] == 999)
        }
    }

    /// The row over the projects is drawn again when who is in a count changes, not at each agent's step.
    @Test func theSummaryRedrawsOnlyWhenItsCountsChange() async throws {
        _ = testHome
        let app = AppModel(builtins: [])
        var s = Session(id: "s", worktreeId: nil, cwd: "/", command: "claude", agent: "claude", status: .working)
        let other = Session(id: "o", worktreeId: nil, cwd: "/", command: "claude", agent: "claude", status: .working)
        app.sessions = [s, other]
        let summary = AgentSummary(app: app)
        let tick = try #require(summary.tick)   // the times in "2 working · 4m" move on by the minute
        let capsule = try #require(find(summary) { $0.toolTip?.hasPrefix("Show the next agent") == true })
        capsule.toolTip = "probe"
        s.progress = 40
        s.summary = "Reading the code"
        app.sessions = [s, other]
        try await settle()
        #expect(capsule.toolTip == "probe")
        s.status = .idle
        s.statusAt = Date()
        app.sessions = [s, other]
        try await settle()
        #expect(capsule.toolTip != "probe")
        #expect(summary.tick === tick)   // still set for the same minute: not made again
    }
}

/// Untitled chats of one agent in one workspace are numbered oldest first, from an index the sessions' change drops.
@MainActor @Test func untitledChatsAreNumberedAndRenumbered() {
    _ = testHome
    let app = AppModel(builtins: [])
    func chat(_ id: String, _ ago: TimeInterval, in w: String = "w") -> Session {
        var s = Session(id: id, worktreeId: w, cwd: "/", command: "claude", agent: "claude", status: .working)
        s.createdAt = Date(timeIntervalSinceNow: -ago)
        return s
    }
    var first = chat("1", 30)
    let second = chat("2", 20), third = chat("3", 10), elsewhere = chat("4", 5, in: "v")
    app.sessions = [third, first, second, elsewhere]
    let name = app.catalog.name("claude")
    #expect(app.sessions.map(app.catalog.displayName) == ["\(name) 3", name, "\(name) 2", name])
    first.title = "Login"
    app.sessions = [third, first, second, elsewhere]
    #expect(app.sessions.map(app.catalog.displayName) == ["\(name) 2", "Login", name, name])
}

/// The consoles an agent started, from the index: ended ones too, its own only; a new list of sessions makes it again.
@MainActor @Test func theConsolesAnAgentStartedComeFromAnIndex() {
    _ = testHome
    let app = AppModel(builtins: [])
    let agent = Session(id: "a", worktreeId: "w", cwd: "/", command: "claude", agent: "claude")
    var run = Session(id: "r", worktreeId: "w", cwd: "/", command: "swift build", agent: "custom")
    run.startedBy = "a"
    app.sessions = [agent, run]
    #expect(app.started(by: "a").map(\.id) == ["r"] && app.started(by: "r").isEmpty)
    #expect(app.owner(of: run)?.id == "a" && app.owner(of: agent) == nil)
    var other = run
    other.worktreeId = "v"   // gone to another workspace: no longer on the agent's line
    app.sessions = [agent, other]
    #expect(app.started(by: "a").map(\.id) == ["r"] && app.owner(of: other) == nil)
    app.sessions = [agent]
    #expect(app.started(by: "a").isEmpty)
}
