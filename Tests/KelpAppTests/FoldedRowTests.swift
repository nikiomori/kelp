import AppKit
import Core
import DesignKit
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

/// The logos shown and the number after them.
@MainActor private func marks(_ cell: SidebarCell) -> (logos: Int, words: String) {
    let buttons = cell.stack.subviews.compactMap { $0 as? PointerButton }.filter { !$0.isHidden }
    return (buttons.filter(\.title.isEmpty).count, buttons.first { !$0.title.isEmpty }?.title ?? "")
}

extension OneAtATime {
    /// Only chats at work or waiting for you show their logo, two at most; the rest are one number.
    @Test func aFoldedProjectShowsALogoOnlyForChatsAtWork() throws {
        try withSidebar(repos: [atlas], worktrees: [home], sessions: chats([.idle, .working, .idle, .idle, .idle])) {
            vc, o in
            vc.toggle(try #require(o.item(atRow: 0) as? SidebarController.Node))
            let cell = try foldedRow(vc, o, width: 280)
            #expect(marks(cell).logos == 1 && marks(cell).words == "+4")
            #expect(cell.stack.toolTip?.split(separator: "\n").count == 5)   // the tooltip still names them all
        }
        let busy = chats([.waiting, .working, .working, .idle])
        try withSidebar(repos: [atlas], worktrees: [home], sessions: busy) { vc, o in
            vc.toggle(try #require(o.item(atRow: 0) as? SidebarController.Node))
            let cell = try foldedRow(vc, o, width: 280)
            #expect(marks(cell).logos == 2 && marks(cell).words == "+2")
        }
    }

    /// Nobody at work: the count alone, which unfolds the row as "+N" did.
    @Test func aFoldedProjectWithOnlyReadyChatsShowsTheirCount() throws {
        try withSidebar(repos: [atlas], worktrees: [home], sessions: chats([.idle, .paused])) { vc, o in
            vc.toggle(try #require(o.item(atRow: 0) as? SidebarController.Node))
            let cell = try foldedRow(vc, o, width: 280)
            #expect(marks(cell).logos == 0 && marks(cell).words == "2")
            try #require(cell.stack.subviews.compactMap { $0 as? PointerButton }.first { $0.title == "2" })
                .performClick(nil)
            #expect(o.numberOfRows > 1)
        }
    }

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
