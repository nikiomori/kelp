import AppKit
import Core
import Testing

@testable import KelpKit

// A folded project's row: its name, its chats' logos and count, its git marks.
private let atlas = Repo(id: "r1", name: "Atlas", path: "/tmp/kelp-screen-atlas")
private let home = Worktree(id: "w1", repoId: "r1", branch: "main", path: atlas.path)

private func chats(_ statuses: [AgentStatus]) -> [Session] {
    statuses.enumerated().map {
        Session(
            worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: $0.element,
            title: "Chat \($0.offset)")
    }
}

/// The folded row's cell, laid out in a sidebar `width` wide.
@MainActor private func foldedRow(_ vc: SidebarController, _ o: NSOutlineView, width: CGFloat) throws -> SidebarCell {
    vc.view.frame.size.width = width
    vc.view.layoutSubtreeIfNeeded()
    let cell = try #require(o.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarCell)
    cell.layoutSubtreeIfNeeded()
    return cell
}

extension OneAtATime {
    /// A narrow sidebar: the marks give way, the folded project's name stays whole (it was cut to "K…").
    @Test func aFoldedProjectsNameKeepsItsRoomFromItsMarks() throws {
        try withSidebar(repos: [atlas], worktrees: [home], sessions: chats(Array(repeating: .working, count: 6))) {
            vc, o in
            vc.toggle(try #require(o.item(atRow: 0) as? SidebarController.Node))
            for width in stride(from: 120.0, through: 220, by: 10) {
                let name = try foldedRow(vc, o, width: width).title
                #expect(name.frame.width >= name.intrinsicContentSize.width - 0.5, "\(width) pt sidebar")
            }
        }
    }
}
