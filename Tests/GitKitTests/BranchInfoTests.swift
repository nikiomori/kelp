import Foundation
import TestSupport
import Testing

@testable import Core
@testable import GitKit

/// What Source Control shows about branches, read from one for-each-ref: checked against what git itself says.
@Test func branchInfoMatchesGitInEveryState() throws {
    let origin = try tempRepo()
    let repo = tmp().path
    try Git.run(["clone", "-q", origin, repo], cwd: TestIsolation.root, remotes: .none)
    func commit(_ dir: String, _ name: String) throws {
        try name.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
        try Git.run(["add", name], cwd: dir, remotes: .none)
        try Git.run(["commit", "-qm", name], cwd: dir, remotes: .none)
    }
    func short(_ ref: String) throws -> String {
        try Git.run(["rev-parse", "--short", ref], cwd: repo, remotes: .none).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Even with origin, then 2 ahead and 1 behind.
    var b = try Git.branches(repo, remotes: .none), head = try short("HEAD")
    #expect(b.current == "main" && b.upstream == "origin/main" && b.ahead == 0 && b.behind == 0 && b.head == head)
    #expect(b.remote == ["origin/main"] && b.local == ["main"] && !b.merging)   // origin/HEAD isn't a branch
    try commit(repo, "x")
    try commit(repo, "y")
    try commit(origin, "z")
    try Git.run(["fetch", "-q"], cwd: repo, remotes: .none)
    b = try Git.branches(repo, remotes: .none)
    head = try short("HEAD")
    #expect(b.ahead == 2 && b.behind == 1 && b.head == head)

    // A branch without an upstream, and one whose upstream was deleted.
    try Git.run(["switch", "-q", "-c", "feat/a"], cwd: repo, remotes: .none)
    b = try Git.branches(repo, remotes: .none)
    #expect(b.current == "feat/a" && b.upstream == nil && b.local == ["feat/a", "main"])
    #expect(b.ahead == 2)   // x and y are on no remote: what the graph marks unpushed
    try Git.run(["push", "-q", "-u", "origin", "feat/a"], cwd: repo, remotes: .none)
    #expect(try Git.branches(repo, remotes: .none).upstream == "origin/feat/a")
    try Git.run(["branch", "-q", "-D", "feat/a"], cwd: origin, remotes: .none)
    try Git.run(["fetch", "-q", "--prune"], cwd: repo, remotes: .none)
    b = try Git.branches(repo, remotes: .none)
    #expect(b.current == "feat/a" && b.upstream == nil && b.remote == ["origin/main"])
    #expect(b.ahead == 2)   // origin/feat/a, which had them, is gone

    // Detached: no current branch, HEAD still named.
    try Git.run(["switch", "-q", "--detach", "HEAD~1"], cwd: repo, remotes: .none)
    b = try Git.branches(repo, remotes: .none)
    head = try short("HEAD")
    #expect(b.current == nil && b.head == head && b.upstream == nil)

    // Before the first commit: the branch HEAD will be on, no hash.
    let empty = tmp().path
    try Git.run(["init", "-q", "-b", "trunk"], cwd: empty, remotes: .none)
    b = try Git.branches(empty, remotes: .none)
    #expect(b.current == "trunk" && b.head == nil && b.local.isEmpty)
}

@Test func oneFilesStatusLooksOnlyAtIt() throws {
    let repo = try tempRepo()
    defer { try? FileManager.default.removeItem(atPath: repo) }
    try "n\n".write(toFile: repo + "/new.txt", atomically: true, encoding: .utf8)
    try "e\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
    #expect(try Git.status(repo, only: "new.txt", remotes: .none).map(\.path) == ["new.txt"])
    #expect(try Set(Git.status(repo, remotes: .none).map(\.path)) == [".env", "new.txt", "f.txt"])
    #expect(try Git.diff(repo, source: .unstaged, file: "new.txt", remotes: .none).map(\.path) == ["new.txt"])
}

@Test func aFileDeletedFromTheFolderLeavesTheList() throws {
    let repo = try tempRepo()
    defer { try? FileManager.default.removeItem(atPath: repo) }
    try FileManager.default.createDirectory(atPath: repo + "/d", withIntermediateDirectories: true)
    try "x\n".write(toFile: repo + "/d/kept.txt", atomically: true, encoding: .utf8)
    try "y\n".write(toFile: repo + "/gone.txt", atomically: true, encoding: .utf8)
    try Git.run(["add", "."], cwd: repo, remotes: .none)
    try Git.run(["commit", "-qm", "files"], cwd: repo, remotes: .none)
    try FileManager.default.removeItem(atPath: repo + "/gone.txt")
    try "n\n".write(toFile: repo + "/new.txt", atomically: true, encoding: .utf8)
    #expect(try Set(ProjectFiles.list(repo, remotes: .none)) == ["f.txt", ".env", "d/kept.txt", "new.txt"])
}

@Test func ignoredFilesListTheirFoldersClosed() throws {
    let repo = try tempRepo()
    defer { try? FileManager.default.removeItem(atPath: repo) }
    try FileManager.default.createDirectory(atPath: repo + "/build/sub", withIntermediateDirectories: true)
    for f in ["build/out.o", "build/sub/x.o", "notes.log", ".gitignore"] {
        try "x\n".write(toFile: repo + "/" + f, atomically: true, encoding: .utf8)
    }
    try "build/\n*.log\n".write(toFile: repo + "/.gitignore", atomically: true, encoding: .utf8)
    #expect(try Set(ProjectFiles.ignored(repo, remotes: .none)) == ["build/", "notes.log"])
    #expect(try Set(ProjectFiles.ignored(repo, folder: "build/", remotes: .none)) == ["build/out.o", "build/sub/"])
    #expect(throws: GitError.self) { try ProjectFiles.ignored(repo, folder: "build/../..", remotes: .none) }
}

@Test func fuzzyMatchesWholeCharacters() {
    let nfd = "cafe\u{301}/menu.txt", nfc = "caf\u{E9}/menu.txt"
    #expect(fuzzy(nfd, "café") != nil && fuzzy(nfc, "cafe\u{301}") != nil)   // either way it's stored
    #expect(fuzzy("旗祥/一覧.md", "日") == nil)   // 日's UTF-8 bytes are in 旗祥, the letter isn't
    #expect(fuzzy("Отчёт/План.md", "план") != nil)
}

@Test func aSparseCheckoutListsOnlyWhatsCheckedOut() throws {
    let repo = try tempRepo()
    defer { try? FileManager.default.removeItem(atPath: repo) }
    for d in ["a", "b"] {
        try FileManager.default.createDirectory(atPath: repo + "/" + d, withIntermediateDirectories: true)
        try "\(d)\n".write(toFile: repo + "/\(d)/file.txt", atomically: true, encoding: .utf8)
    }
    try Git.run(["add", "."], cwd: repo, remotes: .none)
    try Git.run(["commit", "-qm", "dirs"], cwd: repo, remotes: .none)
    try Git.run(["sparse-checkout", "set", "--cone", "a"], cwd: repo, remotes: .none)
    let files = try ProjectFiles.list(repo, remotes: .none)
    #expect(files.contains("a/file.txt") && !files.contains("b/file.txt"))
}

@Test func theBranchOfAReftableRepository() throws {
    let d = tmp().path
    guard (try? Git.run(["init", "-q", "-b", "trunk", "--ref-format=reftable"], cwd: d, remotes: .none)) != nil else { return }   // git before 2.45
    #expect(try String(contentsOfFile: d + "/.git/HEAD", encoding: .utf8).contains(".invalid"))   // the stub the fast path must not believe
    try Git.run(["commit", "-q", "--allow-empty", "-m", "i"], cwd: d, remotes: .none)
    #expect(try Git.currentBranch(d, remotes: .none) == "trunk")
}
