import AppKit
import Core
import Foundation
import TestSupport
import Testing
import WorkbenchKit

@testable import BuiltinFiles
@testable import KelpKit

extension OneAtATime {
    /// A file comes back in its place, at the line it was on, and only once.
    @Test func aClosedFileComesBackInItsPlaceAtItsLine() async throws {
        let rig = try await AppRig(files: ["a.txt": "1\n2\n3\n4\n", "b.txt": "b\n"])
        defer { rig.done() }
        _ = NSApplication.shared
        rig.app.extensions.reload()
        let area = EditorArea(app: rig.app, workspaceId: rig.workspace.id)
        area.arrangedByHand()
        let a = TabURI.file(rig.repo + "/a.txt"), b = TabURI.file(rig.repo + "/b.txt")
        area.open(a)
        area.open(b)
        let id = try #require(area.layout.tab(uri: a)?.id)
        _ = await area.closeTabAsking(id)
        #expect(area.layout.tab(uri: a) == nil)
        let closed = try #require(rig.app.workbench.closedTabs.all.first)
        #expect(closed.title == "a.txt")
        #expect(closed.index == 0)
        area.reopen(closed)
        #expect(area.layout.focusedGroup?.tabs.map(\.uri) == [closed.uri, b])
        #expect(area.layout.allTabs.count == 2)
    }

    /// What a Don't Save threw away isn't offered, and what Kelp closed itself isn't either.
    @Test func onlyWhatYouClosedIsRemembered() async throws {
        let rig = try await AppRig(files: ["a.txt": "a\n"])
        defer { rig.done() }
        _ = NSApplication.shared
        rig.app.extensions.reload()
        let area = EditorArea(app: rig.app, workspaceId: rig.workspace.id)
        let a = TabURI.file(rig.repo + "/a.txt")
        area.open(a)
        _ = await area.closeTabAsking(try #require(area.layout.tab(uri: a)?.id), remember: false)
        area.open("untitled:1")
        _ = await area.closeTabAsking(try #require(area.layout.allTabs.first?.id))
        #expect(rig.app.workbench.closedTabs.all.isEmpty)
    }

    /// A terminal comes back as a new shell, in the old one's tab: a run isn't run again.
    @Test func aClosedTerminalComesBackAsAShell() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let area = EditorArea(app: rig.app, workspaceId: rig.workspace.id)
        let s = try #require(await rig.app.call(SessionCreate(worktreeId: rig.workspace.id, agent: "shell")))
        rig.app.upsert(s)
        let uri = TabURI.session(s.id)
        area.open(uri)
        _ = await area.closeTabAsking(try #require(area.layout.tab(uri: uri)?.id))
        let closed = try #require(rig.app.workbench.closedTabs.all.first)
        area.reopen(closed)
        #expect(try await waitFor { area.layout.tab(uri: uri) == nil })
        #expect(area.layout.allTabs.count == 1)
        let now = try #require(area.layout.allTabs.first)
        let new = try #require(rig.app.session(TabURI.body(now.uri)))
        #expect(new.id != s.id && new.agent == "shell")
    }
}

extension OneAtATime {
    /// The last tab of a chat takes its row and the row's sessions with it: what you closed there survives, on the row shown
    /// instead, for ⇧⌘T to resume.
    @Test func aChatsLastTabCanStillComeBack() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let chat = try await rig.client.call(WorkspaceCreate(repoId: rig.project.id))
        let s = try await rig.client.call(SessionCreate(worktreeId: chat.id, agent: "shell"))
        _ = try await rig.client.call(SessionKill(id: s.id))
        let bench = rig.app.workbench
        bench.closedTabs.remember(
            ClosedTab(uri: TabURI.session(s.id), title: "Claude", workspace: chat.id, group: nil, index: nil))
        #expect(await bench.keepClosedTabs(of: chat, on: rig.workspace))
        _ = try await rig.client.call(WorktreeRemove(id: chat.id))
        #expect(bench.closedTabs.all.first?.workspace == rig.workspace.id)
        #expect(try await rig.client.call(SessionList()).first { $0.id == s.id }?.worktreeId == rig.workspace.id)
    }

    /// A session there that can't move (the row it would go to is archived): the chat must stay, or its record goes
    /// with it. One whose record is already gone has nothing to keep, and doesn't hold the chat.
    @Test func aClosedTabThatCantMoveKeepsItsChat() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let chat = try await rig.client.call(WorkspaceCreate(repoId: rig.project.id))
        let gone = try await rig.client.call(WorkspaceCreate(repoId: rig.project.id))
        _ = try await rig.client.call(WorktreeArchive(id: gone.id))
        let s = try await rig.client.call(SessionCreate(worktreeId: chat.id, agent: "shell"))
        _ = try await rig.client.call(SessionKill(id: s.id))
        rig.app.upsert(s)
        let bench = rig.app.workbench
        bench.closedTabs.remember(
            ClosedTab(uri: TabURI.session(s.id), title: "Claude", workspace: chat.id, group: nil, index: nil))
        #expect(await bench.keepClosedTabs(of: chat, on: gone) == false)
        #expect(bench.closedTabs.all.first?.workspace == chat.id)
        #expect(try await rig.client.call(SessionList()).first { $0.id == s.id }?.worktreeId == chat.id)

        let other = try await rig.client.call(WorkspaceCreate(repoId: rig.project.id))
        bench.closedTabs.remember(
            ClosedTab(uri: TabURI.session("no-such-session"), title: "Old", workspace: other.id, group: nil, index: nil)
        )
        #expect(await bench.keepClosedTabs(of: other, on: rig.workspace))
    }
}

extension OneAtATime {
    /// An empty group stays when the screen leaves it, as it was set up: it goes by itself only after a day with
    /// nothing in it. One with a tab, or on screen, stays however old.
    @Test func anEmptyGroupStaysADayAfterTheScreenLeftIt() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let app = rig.app, bench = rig.app.workbench, actions = WorkspaceActions(rig.app)
        await app.uiState.load()
        app.connected = true
        let empty = try await rig.client.call(WorkspaceCreate(repoId: rig.project.id))
        let full = try await rig.client.call(WorkspaceCreate(repoId: rig.project.id))
        let stale = try await rig.client.call(WorkspaceCreate(repoId: rig.project.id))
        app.worktrees = try await rig.client.call(WorktreeList(repoId: rig.project.id))
        var layout = bench.layouts[full.id]
        _ = layout.add("untitled:1", to: nil)
        bench.layouts[full.id] = layout
        actions.emptied(stale.id, now: Date(timeIntervalSinceNow: -2 * WorkspaceActions.emptyFor))
        let open = { try await rig.client.call(WorktreeList(repoId: rig.project.id)).map(\.id) }
        // Leaving the empty group closes the one empty for two days, and not the one just left.
        actions.left(empty.id)
        #expect(try await waitFor { try await !open().contains(stale.id) })
        #expect(try await open().contains(empty.id))
        actions.closeIdle(now: Date(timeIntervalSinceNow: WorkspaceActions.emptyFor + 60))
        #expect(try await waitFor { try await !open().contains(empty.id) })
        #expect(try await Set(open()).isSuperset(of: [full.id, rig.workspace.id]))
    }
}
