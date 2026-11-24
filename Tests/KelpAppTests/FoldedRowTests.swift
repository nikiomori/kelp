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

/// The words of each row, top to bottom.
@MainActor private func names(_ o: NSOutlineView) -> [[String]] {
    @MainActor func words(_ v: NSView) -> [String] {
        let own = (v as? NSTextField).flatMap { $0.isHidden || $0.stringValue.isEmpty ? nil : [$0.stringValue] } ?? []
        return own + v.subviews.filter { !$0.isHidden }.flatMap(words)
    }
    return (0..<o.numberOfRows).map { r in o.view(atColumn: 0, row: r, makeIfNecessary: true).map(words) ?? [] }
}

extension OneAtATime {
    /// A branch a chat made for itself, holding no chats, is no row of its own: the chat's row marks it, beside its
    /// name, and a click there opens the branch's changes.
    @Test func aChatsOwnBranchIsAMarkOnItsRow() throws {
        var branch = Worktree(id: "b", repoId: "r1", branch: "fix-login", path: "/tmp/kelp-screen-atlas-b")
        let chat = Session(
            id: "c", worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: .working, title: "Login")
        branch.madeBy = "c"
        try withSidebar(repos: [atlas], worktrees: [home, branch], sessions: [chat]) { vc, o in
            #expect(names(o).count == 2)   // the project and the chat: the branch has no row
            let cell = try #require(o.view(atColumn: 0, row: 1, makeIfNecessary: true) as? SidebarCell)
            vc.view.layoutSubtreeIfNeeded()
            cell.layoutSubtreeIfNeeded()
            #expect(cell.folder?.id == "b")
            #expect(cell.hasBadge.pr && !cell.pr.isHidden)
            // Under the pointer the mark spells its branch out, and the chat's card shows that branch.
            #expect(!cell.pr.attributedTitle.string.contains("fix-login"))
            cell.spell(cell.pr, true)
            #expect(cell.pr.attributedTitle.string.contains("fix-login"))
            cell.spell(cell.pr, false)
            #expect(!cell.pr.attributedTitle.string.contains("fix-login"))
            let card = try #require(CardModel(.agent("c"), app: vc.app))
            #expect(card.branch?.id == "b" && card.folder == "b")
            // Short of room for both, the branch's mark stays and the changes dot steps aside.
            let row = try #require(cell.pr.superview as? NSStackView)
            for width in stride(from: 280, through: 120, by: -2) {
                cell.hasBadge = (true, true, false)
                vc.view.frame.size.width = CGFloat(width)
                vc.view.layoutSubtreeIfNeeded()
                cell.fitBadges()
                if row.visibilityPriority(for: cell.changes) == .mustHold {
                    #expect(row.visibilityPriority(for: cell.pr) == .mustHold, "at \(width) pt")
                }
            }
        }
    }

    /// A project with a second screen gives its own screen a row, named by its branch. Folded, it keeps both screens'
    /// rows, each with its chats' logos, and picking one of them leaves the project folded.
    @Test func aFoldedProjectKeepsItsScreensRows() throws {
        let group = Worktree(
            id: "g", repoId: "r1", branch: "main", path: atlas.path, note: "Release",
            createdAt: Date(timeIntervalSinceNow: 60))
        let here = Session(
            worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: .working, title: "Here")
        let there = Session(
            worktreeId: "g", cwd: "/", command: "claude", agent: "claude", status: .waiting, title: "There")
        try withSidebar(repos: [atlas], worktrees: [home, group], sessions: [here, there]) { vc, o in
            let open = names(o)
            #expect(open.count == 5)   // the project, its own screen, Here, Release, There
            #expect(open[1].contains("main") && open[2].contains("Here") && open[3].contains("Release"))
            // The project's card holds every screen's chats, each screen's under its name.
            let project = try #require(o.item(atRow: 0) as? SidebarController.Node)
            #expect(project.cardKind == .project("r1"))
            let card = try #require(CardModel(project.cardKind, app: vc.app))
            #expect(card.agents.map(\.id) == [here.id, there.id])
            #expect(card.heading(at: 0) != nil && card.heading(at: 1) == "Release")
            vc.toggle(try #require(o.item(atRow: 0) as? SidebarController.Node))
            let folded = names(o)
            #expect(folded.count == 3 && folded[1].contains("main") && folded[2].contains("Release"))
            let screen = try #require(o.view(atColumn: 0, row: 2, makeIfNecessary: true) as? SidebarCell)
            #expect(screen.stack.total == 1)   // There, as a logo
            o.selectRowIndexes([2], byExtendingSelection: false)
            #expect(names(o).count == 3)
        }
    }

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

    /// A chat that only waits for its command is a ring of dots on its folded project's logo, as in its tab and on its
    /// own row, and an arc again once the command ended, on the same logo. The logos copied the status alone, so the
    /// chat turned there as an arc while its tab showed the dots.
    @Test func aFoldedProjectsLogoSaysItsChatWaitsForItsCommand() throws {
        var waiting = chats([.working])
        waiting[0].awaiting = "swift test"
        try withSidebar(repos: [atlas], worktrees: [home], sessions: waiting) { vc, o in
            vc.toggle(try #require(o.item(atRow: 0) as? SidebarController.Node))
            let cell = try foldedRow(vc, o, width: 280)
            @MainActor func mark(_ view: NSView) -> StatusMark? {
                view as? StatusMark ?? view.subviews.lazy.compactMap(mark).first
            }
            let logo = try #require(mark(cell.stack))
            #expect(logo.waitsForCommand)
            waiting[0].awaiting = nil
            cell.stack.show(waiting, vc.app)
            #expect(!logo.waitsForCommand && mark(cell.stack) === logo)
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

    /// The pointer on the row brings its "+" and leaves the git marks as dots; on the changes dot itself, its counts.
    @Test func aGitMarkSaysItsWordsOnlyUnderThePointerOnIt() throws {
        try withSidebar(repos: [atlas], worktrees: [home], sessions: []) { vc, o in
            let cell = try foldedRow(vc, o, width: 280)
            cell.counts = NSAttributedString(string: "+2 −1")
            cell.showHoverControls(true)
            #expect(cell.changes.attributedTitle.string == "\u{FFFC}")   // the drawn dot
            @MainActor func pointer(_ type: NSEvent.EventType) throws -> NSEvent {
                try #require(
                    NSEvent.enterExitEvent(
                        with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                        eventNumber: 0, trackingNumber: 0, userData: nil))
            }
            cell.changes.mouseEntered(with: try pointer(.mouseEntered))
            #expect(cell.changes.attributedTitle.string == "+2 −1")
            cell.changes.mouseExited(with: try pointer(.mouseExited))
            #expect(cell.changes.attributedTitle.string == "\u{FFFC}")   // the drawn dot
        }
    }
}
