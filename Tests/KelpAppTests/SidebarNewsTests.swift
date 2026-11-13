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
            #expect(Set(vc.rows(showing: [kid]).map(\.key)) == ["a:a", "p:r1"])   // its parent's row stands for it
            #expect(Set(vc.rows(showing: [b]).map(\.key)) == ["a:b", "w:w2", "p:r1"])
        }
        let place = SidebarController.place(a)
        a.title = "Renamed"
        a.status = .waiting
        #expect(SidebarController.place(a) == place)   // news: no rows move
        a.status = .exited
        #expect(SidebarController.place(a) != place)   // ended: its row goes
    }
}
