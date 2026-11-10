import Core
import Foundation
import Testing

@testable import KelpKit

/// A file two folders of one project change (not committed, or on a branch since its base) is marked in both, with the
/// other's branch; another project's files and a second workspace on the same folder don't count.
@MainActor @Test func aFileTwoFoldersOfAProjectChangeIsMarkedInBoth() {
    _ = testHome
    let m = AppModel(builtins: [])
    m.worktrees = [
        Worktree(id: "m", repoId: "r", branch: "main", path: "/tmp/p"),
        Worktree(id: "s", repoId: "r", branch: "main", path: "/tmp/p"),
        Worktree(id: "a", repoId: "r", branch: "fix-login", path: "/tmp/p-a"),
        Worktree(id: "o", repoId: "other", branch: "x", path: "/tmp/q")
    ]
    func land(_ id: String, _ changed: [String], branch: [String]? = nil) {
        var e = GitEvent(worktree: id, changes: changed.map { FileChange(path: $0, index: ".", worktree: "M") })
        e.branchFiles = branch
        m.land(e)
    }
    land("m", ["Login.swift", "README.md"])
    land("s", ["Login.swift", "README.md"])
    land("a", ["App.swift"], branch: ["Login.swift"])
    land("o", ["App.swift"])
    #expect(m.sharedFiles("a") == ["Login.swift": ["main"]])
    #expect(m.sharedFiles("m") == ["Login.swift": ["fix-login"]])
    #expect(m.sharedFiles("o").isEmpty)
    #expect(GitFolders.sharedTip(m.sharedFiles("a")) == "Also changed on main: Login.swift")
    let many = ["a/1.swift": ["x"], "b/2.swift": ["x"], "3.swift": ["x"], "4.swift": ["x", "y"]]
    #expect(
        GitFolders.sharedTip(many)
            == "Also changed on x: 1.swift, 2.swift, 3.swift and 1 more\nAlso changed on y: 4.swift")
}
