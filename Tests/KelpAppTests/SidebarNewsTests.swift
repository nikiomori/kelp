import AppKit
import Core
import Testing

@testable import KelpKit

private let atlas = Repo(id: "r1", name: "Atlas", path: "/tmp/kelp-screen-atlas")

extension OneAtATime {
    /// An agent's news updates the rows that show it, not every row in the list (they were each told again, several times
    /// a second while agents work); the tree is built again only when a row comes, goes or moves.
    @Test func anAgentsNewsUpdatesOnlyItsRows() throws {
        var a = Session(
            id: "a", worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: .working, title: "One")
        var kid = Session(id: "k", worktreeId: "w1", cwd: "/", command: "codex", agent: "codex", status: .working)
        kid.parent = "a"
        let b = Session(
            id: "b", worktreeId: "w2", cwd: "/", command: "claude", agent: "claude", status: .working, title: "Two")
        let group = Worktree(id: "w2", repoId: "r1", branch: "feat", path: "/tmp/kelp-screen-atlas/w2")
        let own = Worktree(id: "w1", repoId: "r1", branch: "main", path: atlas.path)
        try withSidebar(repos: [atlas], worktrees: [own, group], sessions: [a, kid, b]) {
            vc, _ in
            // Its parent's row stands for it, under the project's own screen, which has a row beside the group's.
            #expect(Set(vc.rows(showing: [kid]).map(\.key)) == ["a:a", "w:w1", "p:r1"])
            #expect(Set(vc.rows(showing: [b]).map(\.key)) == ["a:b", "w:w2", "p:r1"])
        }
        let place = SidebarController.place(a)
        a.title = "Renamed"
        a.status = .waiting
        #expect(SidebarController.place(a) == place)   // news: no rows move
        a.status = .exited
        #expect(SidebarController.place(a) != place)   // ended: its row goes
    }

    /// A muted row's bell is a button: a click unmutes it, as the hover card's Unmute does.
    @Test func aMutedRowsBellUnmutesIt() throws {
        try withSidebar(
            repos: [atlas], worktrees: [Worktree(id: "w1", repoId: "r1", branch: "main", path: atlas.path)],
            sessions: []
        ) { vc, o in
            vc.app.arrangement.mute(["r1"], until: Mutes.forever)
            let cell = try #require(o.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarCell)
            cell.update()
            #expect(!cell.muted.isHidden)
            cell.muted.performClick(nil)
            #expect(vc.app.arrangement.mutedUntil(["r1"]) == nil)
        }
    }

    /// VoiceOver reads a group's row as one sentence: its name, whether it splits the screen or the code, and its
    /// chats when it has any. A project's row says its name and where it is, as its tooltip does.
    @Test func aGroupsAndAProjectsRowAreOneSentenceForVoiceOver() throws {
        let group = Worktree(
            id: "g", repoId: "r1", branch: "main", path: atlas.path, note: "Merge",
            createdAt: Date(timeIntervalSinceNow: 60))
        let worktrees = [
            Worktree(id: "w1", repoId: "r1", branch: "main", path: atlas.path), group,
            Worktree(id: "b", repoId: "r1", branch: "feat", path: "/tmp/kelp-screen-atlas/b"),
            Worktree(id: "e", repoId: "r1", branch: "fix", path: "/tmp/kelp-screen-atlas/e")
        ]
        let chats = ["g", "g", "b", "b"].map {
            Session(worktreeId: $0, cwd: "/", command: "claude", agent: "claude", status: .working)
        }
        try withSidebar(repos: [atlas], worktrees: worktrees, sessions: chats) { _, o in
            let said: [String] = (0..<o.numberOfRows).compactMap {
                o.view(atColumn: 0, row: $0, makeIfNecessary: true)?.accessibilityLabel()
            }
            for sentence in ["Merge, Group, 2 chats", "feat, Branch, 2 chats", "fix, Branch"] {
                #expect(said.contains(sentence), "\(said)")
            }
            #expect(said.contains { $0.hasPrefix("Atlas, /tmp/kelp-screen-atlas") }, "\(said)")
        }
    }
}
