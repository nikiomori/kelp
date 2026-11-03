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
    #expect(cells == [.asks, .failed, .done, .working])
}

@MainActor @Test func theDockIconLeavesOutWhatNeedsNothing() {
    #expect(DockIcon.cells([session(.idle), session(.exited), session(.done), session(.hibernated)]).isEmpty)   // done and read
    #expect(DockIcon.cells([session(.done, unread: true, parent: "p")]).isEmpty)   // its result goes to its parent
    #expect(DockIcon.cells([session(.working, agent: "shell")]).isEmpty)   // a terminal, not a chat
    #expect(DockIcon.cells([session(.hibernated, unread: true)]) == [.done])   // paused with a result you haven't read
}

@MainActor @Test func thePlanOnTheDockIconTurnsAtTheWarningLevel() {
    #expect(DockIcon.usage(79.6, warnAt: 80) == .usage(percent: 80, high: false))   // reads 80, is under it
    #expect(DockIcon.usage(80, warnAt: 80) == .usage(percent: 80, high: true))
    #expect(DockIcon.usage(99, warnAt: nil) == .usage(percent: 99, high: false))   // warnings are off
}

@MainActor @Test func theDockMenuAnswersAPermissionWithoutOpeningKelp() async throws {
    let rig = try await AppRig()
    _ = NSApplication.shared   // reload applies the theme to NSApp
    rig.app.extensions.reload()   // the setting the Dock Icon menu is made from
    var asks = session(.waiting)
    asks.worktreeId = rig.workspace.id
    asks.summary = "Allow npm test?"
    var works = session(.working)
    works.worktreeId = rig.workspace.id
    rig.app.sessions = [asks, works]
    let menu = DockIcon(app: rig.app).menu()
    let item = try #require(menu.items.first)
    #expect(item.title.contains("Allow npm test?"))
    #expect(item.submenu?.items.map(\.title) == ["Allow", "Deny", "", "Open in Kelp"])
    #expect(menu.items.contains { $0.title == "1 working" && $0.action == nil })
    let icon = try #require(menu.items.first { $0.title == "Dock Icon" }?.submenu)
    #expect(icon.items.map(\.title) == ["Show Application Icon", "Show Agents", "Show Plan Usage"])
    #expect(icon.items.first?.state == .on)   // nothing chosen yet: the default, as the strip says it all
}
