import Testing
import Foundation
import AppKit
import Core
import WorkbenchKit
@testable import KelpKit
@testable import BuiltinFiles

extension OneAtATime {
    /// A file comes back in its place, at the line it was on, and only once.
    @Test func aClosedFileComesBackInItsPlaceAtItsLine() async throws {
        let rig = try await AppRig(files: ["a.txt": "1\n2\n3\n4\n", "b.txt": "b\n"]); defer { rig.done() }
        _ = NSApplication.shared; rig.app.extensions.reload()
        let area = EditorArea(app: rig.app, workspaceId: rig.workspace.id)
        area.arrangedByHand()
        let a = TabURI.file(rig.repo + "/a.txt"), b = TabURI.file(rig.repo + "/b.txt")
        area.open(a); area.open(b)
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
        let rig = try await AppRig(files: ["a.txt": "a\n"]); defer { rig.done() }
        _ = NSApplication.shared; rig.app.extensions.reload()
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
        let rig = try await AppRig(files: [:]); defer { rig.done() }
        let area = EditorArea(app: rig.app, workspaceId: rig.workspace.id)
        let s = try #require(await rig.app.call(SessionCreate(worktreeId: rig.workspace.id, agent: "shell")))
        rig.app.upsert(s)
        let uri = TabURI.session(s.id)
        area.open(uri)
        _ = await area.closeTabAsking(try #require(area.layout.tab(uri: uri)?.id))
        let closed = try #require(rig.app.workbench.closedTabs.all.first)
        area.reopen(closed)
        for _ in 0..<250 where area.layout.tab(uri: uri) != nil { try await Task.sleep(for: .milliseconds(20)) }
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
        let rig = try await AppRig(files: [:]); defer { rig.done() }
        let chat = try await rig.client.call(WorkspaceCreate(repoId: rig.project.id))
        let s = try await rig.client.call(SessionCreate(worktreeId: chat.id, agent: "shell"))
        _ = try await rig.client.call(SessionKill(id: s.id))
        let bench = rig.app.workbench
        bench.closedTabs.remember(ClosedTab(uri: TabURI.session(s.id), title: "Claude", workspace: chat.id, group: nil, index: nil))
        await bench.keepClosedTabs(of: chat, on: rig.workspace)
        _ = try await rig.client.call(WorktreeRemove(id: chat.id))
        #expect(bench.closedTabs.all.first?.workspace == rig.workspace.id)
        #expect(try await rig.client.call(SessionList()).first { $0.id == s.id }?.worktreeId == rig.workspace.id)
    }
}
