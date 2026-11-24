import Core
import Foundation
import GitKit
import Testing

@testable import Daemon

/// The graph's commit menu: Revert adds a commit that undoes one, Create Branch Here makes a branch at it and switches,
/// Cherry-Pick brings it onto the branch (and refuses one the branch has), Check Out leaves HEAD on it with no branch
/// and refuses to lose changes. A commit's details count each file's lines.
@Test func aCommitIsRevertedBranchedFromCherryPickedAndCheckedOut() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await workspace(w, "feat/act")
    func git(_ args: String...) throws -> String { try Git.line(args, cwd: wt.path, remotes: .none) }
    func file(_ name: String) throws -> String { try String(contentsOfFile: wt.path + "/" + name, encoding: .utf8) }
    func act(_ commit: String, _ op: GitCommitAct.Kind, branch: String? = nil) async throws {
        _ = try await w.c.call(GitCommitAct(worktreeId: wt.id, commit: commit, op: op, branch: branch))
    }
    try "b\n".write(toFile: wt.path + "/b.txt", atomically: true, encoding: .utf8)
    _ = try git("add", "b.txt")
    _ = try git("commit", "-qm", "b")
    let b = try git("rev-parse", "HEAD")
    try "hello\nc\n".write(toFile: wt.path + "/a.txt", atomically: true, encoding: .utf8)
    _ = try git("commit", "-qam", "c")
    let c = try git("rev-parse", "HEAD")
    let details = try await w.c.call(GitCommitDetails(id: wt.id, commit: c))
    #expect(details.lines == [FileLines(path: "a.txt", added: 1, removed: 0)])

    try await act(c, .revert)
    #expect(try file("a.txt") == "hello\n" && git("log", "-1", "--format=%s") == "Revert \"c\"")

    try await act(b, .branch, branch: "at-b")
    #expect(try git("branch", "--show-current") == "at-b" && git("rev-parse", "HEAD") == b)
    try await act(c, .cherryPick)
    #expect(try file("a.txt") == "hello\nc\n" && git("log", "-1", "--format=%s") == "c")
    await #expect(throws: (any Error).self) { try await act(b, .cherryPick) }   // the branch has it

    try await act(c, .checkout)
    #expect(try git("branch", "--show-current") == "" && git("rev-parse", "HEAD") == c)
    try "mine\n".write(toFile: wt.path + "/a.txt", atomically: true, encoding: .utf8)
    await #expect(throws: (any Error).self) { try await act(b, .checkout) }   // a.txt differs there: git won't carry it
    #expect(try file("a.txt") == "mine\n" && git("rev-parse", "HEAD") == c)
}
