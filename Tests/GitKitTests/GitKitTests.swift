import Foundation
import TestSupport
import Testing
import WorkbenchKit

@testable import Core
@testable import GitKit

/// This process's git and Kelp see none of the user's own (TestIsolation). Repos live under its folder.
func tempRepo() throws -> String {
    let d = tmp().path
    try Git.run(["init", "-q", "-b", "main"], cwd: d)
    try "a\nb\nc\n".write(toFile: d + "/f.txt", atomically: true, encoding: .utf8)
    try "SECRET=1\n".write(toFile: d + "/.env", atomically: true, encoding: .utf8)
    try Git.run(["add", "f.txt"], cwd: d)
    try Git.run(["commit", "-qm", "init"], cwd: d)
    return d
}

@Test func worktreeLifecycle() throws {
    let repo = try tempRepo()
    let dir = URL(fileURLWithPath: repo + "-wt")
    let p = try Git.addWorktree(repo: repo, branch: "feat/x", base: "main", into: dir, copyFiles: [".env"])
    #expect(FileManager.default.fileExists(atPath: p + "/.env"))
    #expect(try Git.run(["worktree", "list"], cwd: repo).contains("[feat/x]"))
    #expect(try Git.linkedWorktrees(repo).map { ($0.path as NSString).lastPathComponent } == ["feat-x"])   // the main checkout isn't one
    #expect(try Git.linkedWorktrees(repo).first?.branch == "feat/x")
    try Git.run(["worktree", "lock", p], cwd: repo)
    #expect(try Git.linkedWorktrees(repo).first?.locked == true)
    #expect(throws: GitError.self) { try Git.run(["worktree", "remove", p], cwd: repo) }   // what "Remove Clean Worktrees" relies on
    try Git.run(["worktree", "unlock", p], cwd: repo)
    #expect(try Git.linkedWorktrees(repo).first?.locked == false)
    try "dirty".write(toFile: p + "/n.txt", atomically: true, encoding: .utf8)
    #expect(throws: GitError.self) { try Git.removeWorktree(repo: repo, path: p, branch: "feat/x", force: false) }
    try ".env.local\n".write(toFile: repo + "/.git/info/exclude", atomically: true, encoding: .utf8)
    try "local\n".write(toFile: p + "/.env.local", atomically: true, encoding: .utf8)   // ignored: no check sees it
    try Git.removeWorktree(repo: repo, path: p, branch: "feat/x", force: true)
    // What git didn't see went to the Trash with the folder, not away for good.
    let trash = try #require(ProcessInfo.processInfo.environment["KELP_TRASH"])
    let kept = try FileManager.default.subpathsOfDirectory(atPath: trash).filter { $0.hasSuffix("feat-x/.env.local") }
    #expect(!kept.isEmpty)
    #expect(!(try Git.run(["worktree", "list"], cwd: repo)).contains("feat-x"))
    #expect(!(try Git.run(["worktree", "list"], cwd: repo).contains("[feat/x]")))
    #expect(try Git.linkedWorktrees(repo).isEmpty)
}

@Test func diffParseAndHunkStaging() throws {
    let repo = try tempRepo()
    let big = (1...30).map(String.init).joined(separator: "\n") + "\n"
    try big.write(toFile: repo + "/g.txt", atomically: true, encoding: .utf8)
    try Git.run(["add", "g.txt"], cwd: repo)
    try Git.run(["commit", "-qm", "g"], cwd: repo)
    var lines = big.split(separator: "\n").map(String.init)
    lines[1] = "two"
    lines[28] = "twenty-nine"
    try (lines.joined(separator: "\n") + "\n").write(toFile: repo + "/g.txt", atomically: true, encoding: .utf8)

    let d = try Git.diff(repo, source: .unstaged, file: "g.txt")
    #expect(d.count == 1 && d[0].hunks.count == 2)
    #expect(d[0].additions == 2 && d[0].deletions == 2)
    #expect(d[0].hunks[0].lines.first { $0.kind == .add }?.newLine == 2)

    try Git.applyHunk(repo, diff: d[0], hunk: 1, reverse: false)
    let staged = try Git.diff(repo, source: .staged)
    #expect(staged[0].hunks.count == 1 && staged[0].hunks[0].lines.contains { $0.text == "twenty-nine" })
    let rest = try Git.diff(repo, source: .unstaged, file: "g.txt")
    #expect(rest[0].hunks.count == 1 && rest[0].hunks[0].lines.contains { $0.text == "two" })

    // Discarding the unstaged hunk puts line 2 back in the file and leaves the staged one alone.
    try Git.discardHunk(repo, diff: rest[0], hunk: 0)
    let file = try String(contentsOfFile: repo + "/g.txt", encoding: .utf8).split(separator: "\n")
    #expect(file[1] == "2" && file[28] == "twenty-nine")
    #expect(try Git.diff(repo, source: .unstaged, file: "g.txt").isEmpty)
    #expect(try Git.diff(repo, source: .staged).count == 1)
}

@Test func statusUntrackedAndCommit() throws {
    let repo = try tempRepo()
    try "x\n".write(toFile: repo + "/new.txt", atomically: true, encoding: .utf8)
    let s = try Git.status(repo)
    #expect(s.contains { $0.path == "new.txt" && $0.untracked })
    let d = try Git.diff(repo, source: .allUncommitted)
    #expect(d.contains { $0.path == "new.txt" && $0.additions == 1 })
    try Git.stage(repo, files: ["new.txt"])
    _ = try Git.commit(repo, message: "add new")
    #expect(try Git.log(repo, limit: 1).first?.subject == "add new")
}

@Test func mergeAndConflict() throws {
    let repo = try tempRepo()
    let dir = URL(fileURLWithPath: repo + "-wt")
    let p = try Git.addWorktree(repo: repo, branch: "feat", base: "main", into: dir, copyFiles: [])
    try "feat\n".write(toFile: p + "/f.txt", atomically: true, encoding: .utf8)
    try Git.commit(p, message: "feat", all: true)
    try "main\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
    try Git.commit(repo, message: "main", all: true)
    let r = try Git.merge(branch: "feat", into: repo)
    #expect(!r.merged && r.conflicts == ["f.txt"])
    #expect(try Git.status(repo).filter(\.conflicted).isEmpty)   // aborted cleanly
}

@Test func branchDiff() throws {
    let repo = try tempRepo()
    let p = try Git.addWorktree(
        repo: repo, branch: "b", base: "main", into: URL(fileURLWithPath: repo + "-wt"), copyFiles: [])
    try "z\n".write(toFile: p + "/z.txt", atomically: true, encoding: .utf8)
    try Git.stage(p, files: ["z.txt"])
    try Git.commit(p, message: "z")
    #expect(try Git.diff(p, source: .branch(base: "main")).map(\.path) == ["z.txt"])
    let c = try Git.log(p, base: "main")[0].hash
    #expect(try Git.diff(p, source: .commit(c)).map(\.path) == ["z.txt"])
}

@Test func sideBySidePairingAndGaps() {
    func l(_ k: DiffLine.Kind, _ t: String, o: Int? = nil, n: Int? = nil) -> DiffLine {
        DiffLine(kind: k, text: t, oldLine: o, newLine: n)
    }
    let h1 = Hunk(
        header: "@@ -1,3 +1,3 @@", oldStart: 1, newStart: 1,
        lines: [l(.context, "a", o: 1, n: 1), l(.del, "b", o: 2), l(.del, "c", o: 3), l(.add, "B", n: 2)])
    let p = DiffRows.pairs(h1.lines)
    #expect(p.count == 3)
    #expect(p[1].0?.text == "b" && p[1].1?.text == "B")
    #expect(p[2].0?.text == "c" && p[2].1 == nil)
    let h2 = Hunk(header: "@@ -20 +20 @@", oldStart: 20, newStart: 20, lines: [l(.add, "z", n: 20)])
    let rows = DiffRows.build([FileDiff(path: "f", header: "", hunks: [h1, h2], binary: false)], sideBySide: false)
    #expect(rows.contains(.gap(file: 0, from: 3, lines: 17, context: "")))
}

@Test func projectFilesAndSearch() throws {
    let repo = try tempRepo()
    try "ignored.txt\n".write(toFile: repo + "/.gitignore", atomically: true, encoding: .utf8)
    try "needle here\n".write(toFile: repo + "/ignored.txt", atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(atPath: repo + "/src", withIntermediateDirectories: true)
    try "let x = 1\nfind the needle\n".write(toFile: repo + "/src/main.swift", atomically: true, encoding: .utf8)
    let files = try ProjectFiles.list(repo)
    #expect(files.contains("src/main.swift") && !files.contains("ignored.txt"))
    let m = try ProjectFiles.search(repo, query: "needle")
    #expect(m == [SearchMatch(path: "src/main.swift", line: 2, text: "find the needle")])
}

func fuzzy(_ path: String, _ query: String) -> Int? {
    ProjectFiles.fuzzyScore(.init(path), ProjectFiles.fuzzyQuery(query))
}

@Test func fuzzyPrefersFileNames() {
    let a = fuzzy("Sources/KelpApp/AppDelegate.swift", "appdel")!
    let b = fuzzy("Sources/a/p/p/d/e/l.swift", "appdel")!
    #expect(a > b)
    #expect(fuzzy("abc", "abd") == nil)
}

@Test func graphLanesFollowBranchesAndMerges() {
    // M merges P2 into P1; both come from B.
    let g = Git.lanes([("M", ["P1", "P2"]), ("P1", ["B"]), ("P2", ["B"]), ("B", [])])
    #expect(g.map(\.lane) == [0, 0, 1, 0])
    #expect(g[0].top.isEmpty && g[0].bottom == [[0, 0], [0, 1]])
    #expect(g[1].top == [[0, 0], [1, 1]] && g[1].bottom == [[1, 1], [0, 0]])
    #expect(g[2].top == [[0, 0], [1, 1]] && g[2].bottom == [[0, 0], [1, 0]])   // P2 joins B's lane
    #expect(g[3].top == [[0, 0]] && g[3].bottom.isEmpty)
    // The trunk keeps lane 0 when a side branch already waits for the same parent further right.
    let t = Git.lanes([("M", ["L", "D"]), ("D", ["X"]), ("L", ["X"]), ("X", [])])
    #expect(t.map(\.lane) == [0, 1, 0, 0])
    #expect(t[2].bottom == [[1, 1], [0, 0]] && t[3].top == [[0, 0], [1, 0]])
}

@Test func unpushedIsWhatNoRemoteBranchReaches() {
    func c(_ h: String, _ p: [String], _ refs: [String] = []) -> GraphCommit {
        GraphCommit(hash: h, parents: p, author: "", date: 0, subject: "", refs: refs, lane: 0, top: [], bottom: [])
    }
    // main is two ahead of origin/main; "side" was never published and forks from a pushed commit.
    let list = [
        c("L2", ["L1"], ["HEAD -> main"]), c("S", ["B"], ["side"]), c("L1", ["R"]),
        c("R", ["B"], ["origin/main", "origin/HEAD"]), c("B", [])
    ]
    #expect(Git.unpushed(list, remotes: ["origin/main"]) == ["L2", "L1", "S"])
    #expect(Git.unpushed(list, remotes: []).isEmpty)   // no remote at all: nothing to mark
}

@Test func commitDetailsHaveTheBodyTheEmailAndTheSize() throws {
    let repo = try tempRepo()
    try "a\nB\nc\nd\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
    try Data([0, 1, 2, 0]).write(to: URL(fileURLWithPath: repo + "/blob.bin"))
    try Git.run(["add", "f.txt", "blob.bin"], cwd: repo)
    try Git.run(
        [
            "commit", "-q", "--author=Ada <ada@example.com>", "-m", "fix: b", "-m",
            "Why it changed,\nwrapped.\n\nSecond paragraph."
        ], cwd: repo)
    let d = try Git.commitDetails(repo, commit: "HEAD")
    #expect(
        d
            == CommitDetails(
                body: "Why it changed,\nwrapped.\n\nSecond paragraph.", email: "ada@example.com", files: 2, added: 2,
                removed: 1))
    #expect(try Git.commitDetails(repo, commit: "HEAD~1").body.isEmpty)
}

@Test func graphAndBranchesFromARealRepo() throws {
    let repo = try tempRepo()
    try Git.run(["switch", "-q", "-c", "feature"], cwd: repo)
    try "g\n".write(toFile: repo + "/g.txt", atomically: true, encoding: .utf8)
    try Git.run(["add", "g.txt"], cwd: repo)
    try Git.run(["commit", "-qm", "feature work"], cwd: repo)
    try Git.run(["switch", "-q", "main"], cwd: repo)
    try Git.run(["merge", "-q", "--no-ff", "-m", "merge feature", "feature"], cwd: repo)
    let (commits, more) = try Git.graph(repo, limit: 50)
    #expect(!more && commits.first?.subject == "merge feature" && commits.first?.parents.count == 2)
    #expect(commits.first?.refs.contains { $0.hasPrefix("HEAD -> ") } == true)
    #expect(try Git.commitFiles(repo, commit: commits[0].hash).map(\.path) == ["g.txt"])
    let b = try Git.branches(repo)
    #expect(b.current == "main" && b.local.contains("feature") && !b.merging)
    // Pop keeps what was staged staged.
    try "x\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
    try Git.stage(repo, files: ["f.txt"])
    try Git.stash(repo, pop: false)
    try Git.stash(repo, pop: true)
    #expect(try Git.status(repo).first { $0.path == "f.txt" }?.staged == true)
}

@Test func gitErrorsReadAsOneSentence() {
    let e = GitError(
        args: ["push"], status: 128,
        stderr: "fatal: 'origin' does not appear to be a git repository\nfatal: Could not read from remote repository.")
    #expect(e.message == "'origin' does not appear to be a git repository")
    let c = GitError(
        args: ["switch"], status: 1,
        stderr: "error: Your local changes to the following files would be overwritten by checkout:\n\tf.txt\nAborting")
    #expect(c.message == "Your local changes to the following files would be overwritten by checkout: f.txt")
}

@Test func webLinks() {
    #expect(Git.webRepo("git@github.com:o/r.git")! == ("github.com", "o/r"))
    #expect(Git.webRepo("ssh://git@gitlab.example.com:2222/team/sub/r.git")! == ("gitlab.example.com", "team/sub/r"))
    #expect(Git.webRepo("https://me@bitbucket.org/ws/r.git")! == ("bitbucket.org", "ws/r"))
    #expect(Git.webRepo("/local/path") == nil)
    #expect(
        Git.webURL(remote: "git@github.com:o/r.git", sha: "abc", file: "a b/c.swift", lines: 3...5)
            == "https://github.com/o/r/blob/abc/a%20b/c.swift#L3-L5")
    #expect(
        Git.webURL(remote: "https://gitlab.com/o/r", sha: "abc", file: "c.swift", lines: 7...7)
            == "https://gitlab.com/o/r/-/blob/abc/c.swift#L7")
    #expect(
        Git.webURL(remote: "git@bitbucket.org:o/r.git", sha: "abc", file: "c.swift", lines: 1...2)
            == "https://bitbucket.org/o/r/src/abc/c.swift#lines-1:2")
}

@Test func lineKinds() {
    #expect(LineStats.kind("Sources/App.swift") == .code)
    #expect(LineStats.kind("Tests/AppTests/AppTests.swift") == .tests)
    #expect(LineStats.kind("src/__tests__/a.ts") == .tests)
    #expect(LineStats.kind("web/button.test.tsx") == .tests)
    #expect(LineStats.kind("package-lock.json") == .generated)
    #expect(LineStats.kind("ui/vendor.min.js") == .generated)
    #expect(LineStats.kind("contest/main.go") == .code)
}

@Test func snapshotSeesNewAndChangedFiles() throws {
    let d = tmp().path
    try Git.run(["init", "-q", "-b", "main"], cwd: d)
    try "a\n".write(toFile: d + "/a.txt", atomically: true, encoding: .utf8)
    try Git.run(["add", "."], cwd: d)
    try Git.run(["commit", "-qm", "init"], cwd: d)
    try "a\nb\n".write(toFile: d + "/a.txt", atomically: true, encoding: .utf8)   // changed before the turn: not the agent's
    let base = try Git.snapshotTree(d)
    try "a\nb\nc\n".write(toFile: d + "/a.txt", atomically: true, encoding: .utf8)
    try "new\n".write(toFile: d + "/n.txt", atomically: true, encoding: .utf8)
    let ch = try Git.changesSince(tree: base, cwd: d)
    #expect(ch.map(\.path).sorted() == ["a.txt", "n.txt"])
    #expect(ch.first { $0.path == "a.txt" }?.added == 1)
    #expect(try Git.status(d).contains { $0.untracked && $0.path == "n.txt" })   // the real index is untouched
    #expect(try Git.diff(d, source: .since(tree: base)).count == 2)
}

@Test func hunksAtAFileEndWithoutNewlineStageAndDiscard() throws {
    let repo = try tempRepo()
    try "a\nb".write(toFile: repo + "/n.txt", atomically: true, encoding: .utf8)
    try Git.run(["add", "n.txt"], cwd: repo)
    try Git.run(["commit", "-qm", "n"], cwd: repo)
    try "a\nb\nc".write(toFile: repo + "/n.txt", atomically: true, encoding: .utf8)
    let d = try Git.diff(repo, source: .unstaged, file: "n.txt")
    #expect(d[0].hunks[0].lines.filter { $0.noNewline == true }.count == 2)   // the old "b" and the new "c"
    try Git.applyHunk(repo, diff: d[0], hunk: 0, reverse: false)
    #expect(try Git.diff(repo, source: .unstaged, file: "n.txt").isEmpty)
    try Git.applyHunk(repo, diff: try Git.diff(repo, source: .staged, file: "n.txt")[0], hunk: 0, reverse: true)
    try Git.discardHunk(repo, diff: try Git.diff(repo, source: .unstaged, file: "n.txt")[0], hunk: 0)
    #expect(try String(contentsOfFile: repo + "/n.txt", encoding: .utf8) == "a\nb")
    // A new file without a final newline is staged as it is: nothing left over.
    try "x\ny".write(toFile: repo + "/new.txt", atomically: true, encoding: .utf8)
    try Git.applyHunk(repo, diff: try Git.diff(repo, source: .unstaged, file: "new.txt")[0], hunk: 0, reverse: false)
    #expect(try Git.diff(repo, source: .unstaged, file: "new.txt").isEmpty)
}

@Test func hunksOfAFileThatIsntUTF8Apply() throws {
    let repo = try tempRepo()
    func cp1251(_ s: String) -> Data { s.data(using: .windowsCP1251) ?? Data() }
    try cp1251("привет\nмир\n").write(to: URL(fileURLWithPath: repo + "/ru.txt"))
    try Git.run(["add", "ru.txt"], cwd: repo)
    try Git.run(["commit", "-qm", "ru"], cwd: repo)
    try cp1251("привет\nвсем\n").write(to: URL(fileURLWithPath: repo + "/ru.txt"))
    let d = try Git.diff(repo, source: .unstaged, file: "ru.txt")
    #expect(d[0].latin1 == true)
    try Git.applyHunk(repo, diff: d[0], hunk: 0, reverse: false)
    #expect(try Git.diff(repo, source: .unstaged, file: "ru.txt").isEmpty)
}

@Test func pathsWithCyrillicSpacesAndQuotesReadAsThemselves() throws {
    let repo = try tempRepo()
    let names = ["файл.txt", "a b.txt", "q\"x.txt"]
    for n in names { try "1\n".write(toFile: repo + "/" + n, atomically: true, encoding: .utf8) }
    try Git.stage(repo, files: names)
    try Git.commit(repo, message: "names")
    for n in names { try "2\n".write(toFile: repo + "/" + n, atomically: true, encoding: .utf8) }
    #expect(Set(try Git.status(repo).map(\.path)) == Set(names + [".env"]))
    #expect(Set(try Git.diff(repo, source: .unstaged).map(\.path)) == Set(names + [".env"]))
    try Git.stage(repo, files: ["файл.txt"])
    #expect(try Git.status(repo).first { $0.path == "файл.txt" }?.staged == true)
    let head = try Git.log(repo, limit: 1)[0].hash
    #expect(Set(try Git.commitFiles(repo, commit: head).map(\.path)) == Set(names))
}

@Test func fileNamesArentPatterns() throws {
    let repo = try tempRepo()
    try FileManager.default.createDirectory(atPath: repo + "/p", withIntermediateDirectories: true)
    for n in ["p/[id].tsx", "p/d.tsx"] { try "x\n".write(toFile: repo + "/" + n, atomically: true, encoding: .utf8) }
    try Git.discard(repo, files: ["p/[id].tsx"])
    #expect(!FileManager.default.fileExists(atPath: repo + "/p/[id].tsx"))
    #expect(FileManager.default.fileExists(atPath: repo + "/p/d.tsx"))   // "[id]" isn't "i" or "d"
}

/// Discard's Undo puts back what went, whatever diff tool the user set up for reading (difftastic as diff.external, a
/// textconv driver); a new file waits in the Trash besides, should the Undo be refused.
@Test func aDiscardComesBackWithAnExternalDiffSetUp() throws {
    let repo = try tempRepo()
    try Git.run(["config", "diff.external", "/usr/bin/true"], cwd: repo)
    try "*.txt diff=upper\n".write(toFile: repo + "/.git/info/attributes", atomically: true, encoding: .utf8)
    try Git.run(["config", "diff.upper.textconv", "tr a-z A-Z <"], cwd: repo)
    let before = try String(contentsOfFile: repo + "/f.txt", encoding: .utf8)
    try "mine\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
    try "new\n".write(toFile: repo + "/n.txt", atomically: true, encoding: .utf8)
    let back = try Git.discard(repo, files: ["f.txt", "n.txt"])
    #expect(
        try String(contentsOfFile: repo + "/f.txt", encoding: .utf8) == before
            && !FileManager.default.fileExists(atPath: repo + "/n.txt"))
    let trash = try #require(ProcessInfo.processInfo.environment["KELP_TRASH"])
    #expect(try FileManager.default.subpathsOfDirectory(atPath: trash).contains { $0.hasSuffix("/n.txt") })
    try Git.putBack(repo, patch: back, hunk: false)
    #expect(try String(contentsOfFile: repo + "/f.txt", encoding: .utf8) == "mine\n")
    #expect(try String(contentsOfFile: repo + "/n.txt", encoding: .utf8) == "new\n")
}

@Test func commitAllTakesNewFilesButNotConflicts() throws {
    let repo = try tempRepo()
    try "changed\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
    try "new\n".write(toFile: repo + "/new.txt", atomically: true, encoding: .utf8)
    try Git.commit(repo, message: "all", all: true)
    #expect(try Git.status(repo).isEmpty)
    #expect(Set(try Git.commitFiles(repo, commit: "HEAD").map(\.path)).isSuperset(of: ["f.txt", "new.txt"]))

    let p = try Git.addWorktree(
        repo: repo, branch: "feat", base: "main", into: URL(fileURLWithPath: repo + "-wt"), copyFiles: [])
    try "feat\n".write(toFile: p + "/f.txt", atomically: true, encoding: .utf8)
    try Git.commit(p, message: "feat", all: true)
    try "main\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
    try Git.commit(repo, message: "main", all: true)
    _ = try Git.merge(branch: "feat", into: repo, keepConflicts: true)
    #expect(throws: GitError.self) { try Git.commit(repo, message: "markers", all: true) }
}

/// A reply carries at most `Git.diffBudget` of git's output: a regenerated lock file comes back as its header (still
/// listed, marked too large) while the files around it show, and asked for alone it shows; new files stop being read
/// once the whole is spent.
@Test func aHugeDiffComesBackAsHeadersPastTheBudget() throws {
    let repo = try tempRepo()
    let lock = (0..<40_000).map { "\"package-\($0)\": \"1.0.\($0)\"" }   // ~1.2 MB: its diff is past one file's share of a review
    try (lock.joined(separator: "\n") + "\n").write(toFile: repo + "/a.lock", atomically: true, encoding: .utf8)
    try Git.run(["add", "a.lock"], cwd: repo)
    try Git.run(["commit", "-qm", "lock"], cwd: repo)
    try (lock.map { $0 + "-2" }.joined(separator: "\n") + "\n").write(
        toFile: repo + "/a.lock", atomically: true, encoding: .utf8)
    try "a\nB\nc\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)

    let all = try Git.diff(repo, source: .unstaged)
    let big = try #require(all.first { $0.path == "a.lock" }), small = try #require(all.first { $0.path == "f.txt" })
    #expect(big.tooLarge == true && big.hunks.isEmpty && big.header.contains("+++ b/a.lock"))
    #expect(small.tooLarge == nil && small.hunks.count == 1)
    let alone = try #require(try Git.diff(repo, source: .unstaged, file: "a.lock").first)
    #expect(alone.tooLarge == nil && alone.additions == 40_000)

    // Twelve new files of 900 KB in 1000 lines, 940 KB each with the lines' share: what's left of 8 MB holds eight.
    let line = String(repeating: "x", count: 899) + "\n"
    for i in 0..<12 {
        try String(repeating: line, count: 1000).write(toFile: repo + "/gen\(i).txt", atomically: true, encoding: .utf8)
    }
    let new = try Git.diff(repo, source: .unstaged).filter { $0.path.hasPrefix("gen") }
    #expect(new.count == 12)
    #expect(new.filter { $0.tooLarge == true }.count == 4 && new.filter { !$0.hunks.isEmpty }.count == 8)
}

@Test func untrackedBigFilesArentRead() throws {
    let repo = try tempRepo()
    try Data(repeating: 0x61, count: 1_200_000).write(to: URL(fileURLWithPath: repo + "/big.log"))
    let d = try Git.diff(repo, source: .unstaged, file: "big.log")
    #expect(d.count == 1 && d[0].binary && d[0].hunks.isEmpty)
}

@Test func onlyEventsThatMoveGitStatusCount() {
    #expect(Git.touchesStatus(["/r/src/a.swift"]))
    #expect(Git.touchesStatus(["/r/.git/index", "/r/.git/objects/ab/cd"]))
    #expect(Git.touchesStatus(["/r/.git/refs/heads/main"]))
    #expect(!Git.touchesStatus(["/r/.git/index.lock", "/r/.git/objects/ab/cd", "/r/.git/FETCH_HEAD"]))
}

@Test func diffHeaderPathsUnquote() {
    #expect(Git.unquoted("\"q\\\"x.txt\"") == "q\"x.txt")
    #expect(Git.unquoted("\"\\321\\204.txt\"") == "ф.txt")
    #expect(Git.headerPath("b/a b.txt\t") == "a b.txt")
    #expect(Git.headerPath("/dev/null") == nil)
}

@Test func changesGroupLikeSourceControlListsThem() {
    let parsed = Git.parseStatus(
        "1 MM N... 100644 100644 100644 a b both.swift\0"
            + "1 M. N... 100644 100644 100644 a b staged.swift\0"
            + "1 .M N... 100644 100644 100644 a b edited.swift\0"
            + "u UU N... 100644 100644 100644 100644 a b c conflict.swift\0"
            + "? new.swift\0")
    let g = parsed.grouped
    #expect(g.merge.map(\.path) == ["conflict.swift"])
    #expect(g.staged.map(\.path) == ["both.swift", "staged.swift"])
    #expect(g.changes.map(\.path) == ["both.swift", "edited.swift", "new.swift"])   // a file edited on both sides is in both lists
}

@Test func statusLettersFollowTheColumnTheListShows() {
    let parsed = Git.parseStatus(
        "1 AM N... 100644 100644 100644 a b added.swift\0"
            + "1 .D N... 100644 100644 100644 a b gone.swift\0"
            + "? new.swift\0"
            + "u UU N... 100644 100644 100644 100644 a b c conflict.swift\0")
    #expect(parsed[0].letter(inWorktree: false) == "A" && parsed[0].letter(inWorktree: true) == "M")
    #expect(parsed[1].letter(inWorktree: true) == "D")
    #expect(parsed[2].letter(inWorktree: true) == "U")
    #expect(parsed[3].letter(inWorktree: true) == "!")
    #expect(parsed[0].letter(inWorktree: false, merging: true) == "!")   // everything in the Merge section is a conflict
}

@Test func changedRangesKeepOnlyWhatDiffers() {
    func r(_ a: String, _ b: String) -> (NSRange, NSRange) { DiffRows.changedRanges(a, b) }
    #expect(r("let x = 1", "let x = 2") == (NSRange(location: 8, length: 1), NSRange(location: 8, length: 1)))
    #expect(r("foo(a)", "foo(a, b)") == (NSRange(location: 5, length: 0), NSRange(location: 5, length: 3)))   // an insertion has an empty old side
    #expect(r("same", "same") == (NSRange(location: 4, length: 0), NSRange(location: 4, length: 0)))
    #expect(r("abc", "xyz") == (NSRange(location: 0, length: 3), NSRange(location: 0, length: 3)))
    #expect(r("aXa", "aa") == (NSRange(location: 1, length: 1), NSRange(location: 1, length: 0)))   // the common end can't overlap the common start
}

private func line(_ k: DiffLine.Kind, _ t: String, o: Int? = nil, n: Int? = nil) -> DiffLine {
    DiffLine(kind: k, text: t, oldLine: o, newLine: n)
}
private let sample = FileDiff(
    path: "f.swift", header: "",
    hunks: [
        Hunk(
            header: "@@ -1,2 +1,2 @@", oldStart: 1, newStart: 1,
            lines: [line(.context, "a", o: 1, n: 1), line(.del, "x = 1", o: 2), line(.add, "x = 2", n: 2)])
    ], binary: false)

@Test func changedWordsAreKeyedByFileAndLine() {
    let w = DiffRows.changedWords([sample])
    #expect(w["0:d:2"] == NSRange(location: 4, length: 1) && w["0:a:2"] == NSRange(location: 4, length: 1))
    #expect(w.count == 2)   // the context line has no counterpart
}

@Test func commentsSitUnderTheirLastLineAndResolvedOnesLeave() {
    func c(_ line: Int, _ state: DiffComment.State, _ file: String = "f.swift") -> DiffComment {
        DiffComment(
            worktreeId: "w", file: file, startLine: line, endLine: line, quote: "", text: "t\(line)", state: state)
    }
    let open = c(2, .open), sent = c(2, .sent), done = c(2, .resolved), other = c(2, .open, "g.swift")
    let rows = DiffRows.reviewRows(
        [sample], comments: [open, sent, done, other], sideBySide: false, hideFileRows: false)
    let comments = rows.compactMap { if case .comment(let c) = $0 { c.id } else { nil } }
    #expect(comments == [open.id, sent.id])   // not the resolved one, not another file's
    let at = rows.firstIndex { if case .comment = $0 { true } else { false } } ?? 0
    if case .diff(.line(_, let l)) = rows[at - 1] {
        #expect(l.newLine == 2 && l.kind == .add)
    } else {
        Issue.record("the comment isn't under its line")
    }
}

@Test func oneFileModeHidesTheFileRow() {
    let withFile = DiffRows.reviewRows([sample], comments: [], sideBySide: true, hideFileRows: false)
    let without = DiffRows.reviewRows([sample], comments: [], sideBySide: true, hideFileRows: true)
    #expect(withFile.count == without.count + 1)
    #expect(!without.contains { if case .diff(.file) = $0 { true } else { false } })
}

@Test func remoteWordsAreQuotedForTheHostsShell() {
    #expect(IDE.shellWord("plain") == "'plain'")
    #expect(IDE.shellWord("it's") == "'it'\\''s'")
    #expect(IDE.shellWord("$(touch x); `id`") == "'$(touch x); `id`'")   // single quotes: the shell expands nothing inside
    #expect(RemoteHost.cdArg("~") == "~")
    #expect(RemoteHost.cdArg("~/my project") == "~/'my project'")   // the ~ stays outside so the host expands it
    #expect(RemoteHost.cdArg("/srv/a b") == "'/srv/a b'")
}

@Test func theRemoteCommandRunsTheProgramByNameInsideTheProjectFolder() {
    let r = RemoteHost(host: "box", path: "/srv/app")
    #expect(r.command(nil) == "cd '/srv/app' && exec \"$SHELL\" -l")
    // A local absolute path means nothing on the host: only the program's name is sent. Arguments with spaces and quotes survive one more level of quoting.
    #expect(
        r.command(["/Users/me/.local/bin/claude", "--resume", "a b"]) == "cd '/srv/app' && exec \"$SHELL\" -ilc "
            + IDE.shellWord("'claude' '--resume' 'a b'"))
    #expect(r.command([]) == r.command(nil))
}

@Test func onlyPlainHostNamesFollowSsh() {
    for ok in ["box", "me@box", "10.0.0.2", "box.example.com"] { #expect(RemoteHost.isHost(ok), "\(ok)") }
    for bad in ["", "-oProxyCommand=x", "a b", "a\tb", "a\nb"] {
        #expect(!RemoteHost.isHost(bad), "\(bad.debugDescription)")
    }
}

@Test func remoteAddressesBecomeAHostAndARepoPath() {
    func r(_ s: String) -> String? { Git.webRepo(s).map { "\($0.0) \($0.1)" } }
    #expect(r("git@github.com:o/r.git") == "github.com o/r")
    #expect(r("https://github.com/o/r") == "github.com o/r")
    #expect(r("https://user@gitlab.com/group/sub/r.git") == "gitlab.com group/sub/r")
    #expect(r("ssh://git@host.example:22/o/r") == "host.example o/r")   // the port isn't part of the path
    #expect(r("git@github.com:123/app.git") == "github.com 123/app")   // a number as the owner is an owner, not a port
    #expect(r("/local/path/repo") == nil && r("nothing") == nil)
}

@Test func webLinksPointAtTheCommitAndLinesOnEachSite() {
    func u(_ remote: String, _ lines: ClosedRange<Int>?) -> String? {
        Git.webURL(remote: remote, sha: "abc", file: "src/my file.swift", lines: lines)
    }
    #expect(u("git@github.com:o/r.git", 3...3) == "https://github.com/o/r/blob/abc/src/my%20file.swift#L3")
    #expect(u("git@github.com:o/r.git", 3...9) == "https://github.com/o/r/blob/abc/src/my%20file.swift#L3-L9")
    #expect(u("https://gitlab.com/g/r", 3...9) == "https://gitlab.com/g/r/-/blob/abc/src/my%20file.swift#L3-9")
    #expect(u("https://bitbucket.org/w/r", 3...9) == "https://bitbucket.org/w/r/src/abc/src/my%20file.swift#lines-3:9")
    #expect(u("https://github.com/o/r", nil) == "https://github.com/o/r/blob/abc/src/my%20file.swift")
    #expect(u("not a remote", nil) == nil)
}

@Test func eachSiteHasItsOwnPathsForCIAndPullRequests() {
    let gh = Git.webPages(remote: "git@github.com:o/r.git")
    #expect(
        gh?.forge == "github" && gh?.repo == "https://github.com/o/r" && gh?.ci == "https://github.com/o/r/actions"
            && gh?.pulls == "https://github.com/o/r/pulls")
    let gl = Git.webPages(remote: "ssh://git@gitlab.example.com:2222/team/sub/r.git")
    #expect(
        gl?.forge == "gitlab" && gl?.ci == "https://gitlab.example.com/team/sub/r/-/pipelines"
            && gl?.pulls == "https://gitlab.example.com/team/sub/r/-/merge_requests")
    #expect(Git.webPages(remote: "https://bitbucket.org/w/r")?.pulls == "https://bitbucket.org/w/r/pull-requests")
    #expect(Git.webPages(remote: "/local/path/repo") == nil)
}

@Test func aSnapshotShowsExactlyWhatChangedAndLeavesTheRealIndexAlone() throws {
    let repo = try tempRepo()
    let before = try Git.snapshotTree(repo)
    #expect(try Git.snapshotTree(repo) == before && Git.changesSince(tree: before, cwd: repo).isEmpty)   // nothing changed, same tree
    try "a\nb\nc\nd\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)   // +1 line in a tracked file
    try "x\ny\n".write(toFile: repo + "/new.txt", atomically: true, encoding: .utf8)   // a new file counts too
    let changes = try Git.changesSince(tree: before, cwd: repo).sorted { $0.path < $1.path }
    #expect(
        changes.map(\.path) == ["f.txt", "new.txt"] && changes.map(\.added) == [1, 2]
            && changes.map(\.removed) == [0, 0])
    #expect(try Git.run(["diff", "--cached", "--name-only"], cwd: repo).isEmpty)   // the real index stayed as it was: nothing got staged
    #expect(try Git.status(repo).contains { $0.path == "new.txt" && $0.untracked })
}

@Test func sharedFoldersNeverLinkOutsideTheProject() throws {
    let repo = try tempRepo(), wt = try tempRepo()
    try FileManager.default.createDirectory(atPath: repo + "/node_modules", withIntermediateDirectories: true)
    Git.linkShared(["node_modules", "../outside", "/etc", "a/../../b", "~/x"], repo: repo, worktree: wt)
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: wt + "/node_modules")) != nil)
    #expect(!FileManager.default.fileExists(atPath: (wt as NSString).deletingLastPathComponent + "/outside"))
    #expect(!FileManager.default.fileExists(atPath: wt + "/etc"))
}

@Test func aHostCantNameAFolderOutsideRemote() {
    for bad in [".", "..", "a/b", "../x"] { #expect(!RemoteHost.isHost(bad), "\(bad)") }
}

/// A stuck run that started children is stopped within the time limit. (The review's case, a child keeping the read
/// waiting after git alone was stopped, didn't reproduce here: this passes on the old code too. Stopping the whole
/// tree is kept as the safe way; this checks it doesn't hang.)
@Test func aStuckRunStopsWithItsChildren() throws {
    let t = Date()
    #expect(throws: (any Error).self) {
        try Git.runData(["-c", "sleep 30 & sleep 30; wait"], cwd: "/tmp", executable: "/bin/sh", timeLimit: 0.5)
    }
    #expect(Date().timeIntervalSince(t) < 5)
}

@Test func anUntrackedSymlinkIsShownNotFollowed() throws {
    let repo = try tempRepo()
    try FileManager.default.createSymbolicLink(atPath: repo + "/zero", withDestinationPath: "/dev/zero")
    let d = try #require(try Git.diff(repo, source: .unstaged, file: "zero").first)   // returns at once: /dev/zero isn't read
    #expect(d.hunks.first?.lines.map(\.text) == ["/dev/zero"] && d.header.contains("120000"))
}

@Test func anUntrackedScriptKeepsItsExecutableMode() throws {
    let repo = try tempRepo()
    try "#!/bin/sh\necho hi\n".write(toFile: repo + "/run.sh", atomically: true, encoding: .utf8)
    chmod(repo + "/run.sh", 0o755)
    let d = try #require(try Git.diff(repo, source: .unstaged, file: "run.sh").first)
    #expect(d.header.contains("new file mode 100755"))   // a hunk staged from it keeps the script runnable
}

/// A remote branch name is checked after its "origin/" is taken off: "origin/-Cmain" must not become `git switch -Cmain`.
@Test func switchingRefusesANameThatReadsAsAnOption() throws {
    let repo = try tempRepo()
    let before = try Git.run(["rev-parse", "main"], cwd: repo)
    try Git.run(["switch", "-q", "-c", "other"], cwd: repo)
    try "x\n".write(toFile: repo + "/x.txt", atomically: true, encoding: .utf8)
    try Git.run(["add", "."], cwd: repo)
    try Git.run(["commit", "-qm", "x"], cwd: repo)
    #expect(throws: (any Error).self) { try Git.switchBranch(repo, to: "origin/-Cmain", remote: true) }
    #expect(throws: (any Error).self) { try Git.switchBranch(repo, to: "-Cmain") }
    #expect(try Git.run(["rev-parse", "main"], cwd: repo) == before)   // main wasn't reset onto this branch
}

/// A run past its time limit ends even if it ignores SIGTERM: the thread waiting on it is given back.
@Test func aRunThatIgnoresSIGTERMStillEndsAtItsTimeLimit() throws {
    let start = Date()
    #expect(throws: (any Error).self) {
        try Git.runData(["-c", "trap '' TERM; sleep 30"], cwd: "/tmp", executable: "/bin/sh", timeLimit: 0.5)
    }
    #expect(Date().timeIntervalSince(start) < 10)   // SIGKILL 2 s after the SIGTERM it ignored
}

/// A file whose name has ":" in it is found like any other: the path ends where the tool says it does (NUL).
@Test func searchFindsAFileWithAColonInItsName() throws {
    let repo = try tempRepo()
    try "a needle\n".write(toFile: repo + "/a:b.txt", atomically: true, encoding: .utf8)
    #expect(try ProjectFiles.search(repo, query: "needle") == [SearchMatch(path: "a:b.txt", line: 1, text: "a needle")])
    // git grep -z (remote projects, or no ripgrep) writes NUL after the line number too.
    #expect(ProjectFiles.parseGrep("a:b.txt\u{0}3\u{0}x: y\n") == [SearchMatch(path: "a:b.txt", line: 3, text: "x: y")])
}

/// Every GitKit call that takes a revision or branch name refuses one that git would read as an option, wherever the
/// name came from: none reaches git (a file named by --output= stays as it was).
@Test func revisionsThatReadAsOptionsAreRefusedEverywhere() throws {
    let repo = try tempRepo()
    let victim = NSTemporaryDirectory() + "victim-\(UUID().uuidString).txt"
    try "keep\n".write(toFile: victim, atomically: true, encoding: .utf8)
    let evil = "--output=" + victim
    #expect(throws: GitError.self) { _ = try Git.log(repo, base: evil) }
    #expect(throws: GitError.self) { _ = try Git.diff(repo, source: .branch(base: evil)) }
    #expect(throws: GitError.self) { _ = try Git.diff(repo, source: .commit(evil)) }
    #expect(throws: GitError.self) { _ = try Git.commitFiles(repo, commit: evil) }
    #expect(throws: GitError.self) { try Git.renameBranch(repo, from: "main", to: evil) }
    let into = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wt-\(UUID().uuidString)")
    #expect(throws: GitError.self) {
        _ = try Git.addWorktree(repo: repo, branch: "x", base: evil, into: into, copyFiles: [])
    }
    #expect(try String(contentsOfFile: victim, encoding: .utf8) == "keep\n")
}

/// An undone turn leaves the user's secrets alone, and puts back a committed template and direnv's file like any code.
@Test func onlySecretEnvFilesStayOutOfAnUndo() {
    for n in [".env", ".env.local", ".env.production", "id_rsa", "server.pem", "credentials.json"] {
        #expect(Git.holdsSecrets(n), "\(n)")
    }
    for n in [".env.example", ".env.sample", ".envrc", "env.ts", ".environment", "id_rsa.pub", "keys.ts"] {
        #expect(!Git.holdsSecrets(n), "\(n)")
    }
}
