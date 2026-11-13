import Core
import Foundation
import Testing

@testable import BuiltinGit
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

/// Two workspaces on one project's folder watch its git once, under the folder's key as the sidebar does: the number on
/// the Source Control icon reads what that one watch brings.
@MainActor @Test func workspacesOnOneFolderWatchItsGitOnce() {
    _ = testHome
    let m = AppModel(builtins: [])
    m.repos = [Repo(id: "r", name: "p", path: "/tmp/p")]
    m.worktrees = [
        Worktree(id: "m", repoId: "r", branch: "main", path: "/tmp/p"),
        Worktree(id: "s", repoId: "r", branch: "main", path: "/tmp/p")
    ]
    m.workbench.workspaceId = "s"
    let changed = ChangedFiles(app: m)
    #expect(m.watching.keys.filter { $0.topic == .git }.map(\.key) == ["m"])
    m.land(GitEvent(worktree: "m", changes: [FileChange(path: "a.swift", index: ".", worktree: "M")]))
    #expect(changed.count == 1)
}
