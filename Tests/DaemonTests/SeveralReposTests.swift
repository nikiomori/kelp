import Core
import Foundation
import GitKit
import Testing

@testable import Daemon

/// A project made of repositories side by side, with one change in each of two and none in the third.
private func severalRepos(_ w: World) async throws -> Worktree {
    let parent = tmp().path
    for name in ["be", "fe", "shared"] {
        try FileManager.default.moveItem(atPath: try makeRepo(), toPath: parent + "/" + name)
    }
    let project = try await w.c.call(RepoAdd(path: parent))
    let wt = try #require(try await w.c.call(WorktreeList()).first { $0.repoId == project.id })
    try "fe\n".write(toFile: wt.path + "/fe/a.txt", atomically: true, encoding: .utf8)
    try "be\n".write(toFile: wt.path + "/be/new.txt", atomically: true, encoding: .utf8)
    return wt
}

/// The folder's git methods act on each file's repository, named by the path's first part, as Source Control lists
/// them: before, every one of them failed with "not a git repository".
@Test func aFolderOfRepositoriesStagesDiffsAndDiscardsInEachFilesRepository() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await severalRepos(w)
    #expect(Set(try await w.c.call(GitStatus(id: wt.id)).map(\.path)) == ["fe/a.txt", "be/new.txt"])
    #expect(try await w.c.call(GitDiff(id: wt.id, file: "fe/a.txt")).map(\.path) == ["fe/a.txt"])
    let all = try await w.c.call(GitDiff(id: wt.id)).map(\.path)
    #expect(all == ["be/new.txt", "fe/a.txt"], "\(all)")
    _ = try await w.c.call(GitStage(id: wt.id, files: ["be/new.txt"]))
    #expect(try Git.status(wt.path + "/be", remotes: .none).first?.staged == true)
    _ = try await w.c.call(GitUnstage(id: wt.id, files: ["be/new.txt"]))
    #expect(try Git.status(wt.path + "/be", remotes: .none).first?.staged == false)
    await #expect(throws: RPCError.self) { try await w.c.call(GitStage(id: wt.id, files: ["../x"])) }
    _ = try await w.c.call(GitDiscard(id: wt.id, files: ["fe/a.txt"], undo: "u"))
    #expect(try String(contentsOfFile: wt.path + "/fe/a.txt", encoding: .utf8) == "hello\n")
    _ = try await w.c.call(GitUndoDiscard(id: wt.id, undo: "u"))
    #expect(try String(contentsOfFile: wt.path + "/fe/a.txt", encoding: .utf8) == "fe\n")
}

/// One message commits in each repository with something to commit, and only there (S2: one field, a commit in each).
@Test func aFolderOfRepositoriesCommitsInEachRepositoryWithChanges() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await severalRepos(w)
    let head = { (name: String) in try Git.line(["rev-parse", "HEAD"], cwd: wt.path + "/" + name, remotes: .none) }
    let shared = try head("shared")
    _ = try await w.c.call(GitStage(id: wt.id, files: ["fe/a.txt"]))
    let staged = try await w.c.call(GitCommit(id: wt.id, message: "only staged"))
    #expect(staged.hasPrefix("fe "))   // be's file isn't staged, so be makes no commit
    #expect(try Git.status(wt.path + "/be", remotes: .none).map(\.path) == ["new.txt"])
    let all = try await w.c.call(GitCommit(id: wt.id, message: "the rest", all: true))
    #expect(all.hasPrefix("be "))
    #expect(try Git.status(wt.path + "/be", remotes: .none).isEmpty)
    #expect(try head("shared") == shared)
    await #expect(throws: RPCError.self) { try await w.c.call(GitCommit(id: wt.id, message: "none", all: true)) }
}

/// A commit that fails in one repository after another committed says what was made, since it stays: before, only the
/// error came back, and the commit in the first repository went unnamed.
@Test func aCommitThatFailsInOneRepositoryNamesTheOnesMade() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await severalRepos(w)
    let hook = wt.path + "/fe/.git/hooks/pre-commit"
    try "#!/bin/sh\nexit 1\n".write(toFile: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
    let made = { try Git.line(["rev-parse", "--short", "HEAD"], cwd: wt.path + "/be", remotes: .none) }
    do {
        _ = try await w.c.call(GitCommit(id: wt.id, message: "both", all: true))
        Issue.record("fe's hook refuses its commit")
    } catch {
        let said = "\(error)"
        #expect(said.contains("Committed in be \(try made())") && said.contains("fe:"), "\(said)")
    }
}

/// Own Branch of a folder of repositories (B1): the branch in each of them, as worktrees side by side in one folder,
/// with what isn't a repository linked; removing the group takes each worktree and its branch. Before, the folder had
/// "no branches".
@Test func aFolderOfRepositoriesBranchesInEachOfThem() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await severalRepos(w)
    try FileManager.default.createDirectory(atPath: wt.path + "/notes", withIntermediateDirectories: true)
    let made = try await w.c.call(WorktreeCreate(repoId: wt.repoId, branch: "pay", setup: false)).worktree
    for name in ["be", "fe", "shared"] {
        #expect(Git.headBranch(made.path + "/" + name) == "pay", "\(name)")
        #expect(Git.branchExists(wt.path + "/" + name, "pay", remotes: .none))
    }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: made.path + "/notes") == wt.path + "/notes")
    #expect(try await w.c.call(GitStatus(id: made.id)) == [])
    _ = try await w.c.call(WorktreeRemove(id: made.id))
    #expect(
        try await waitFor(10) {
            !FileManager.default.fileExists(atPath: made.path)
                && !["be", "fe", "shared"].contains { Git.branchExists(wt.path + "/" + $0, "pay", remotes: .none) }
        })
}
