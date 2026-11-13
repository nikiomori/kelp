import Foundation
import Testing

@testable import Core
@testable import GitKit

/// A planned commit takes its files as they are on disk, new and deleted ones too, and leaves the rest staged alone.
@Test func commitOnlyTheseFiles() throws {
    let repo = try tempRepo()
    try "n\n".write(toFile: repo + "/new.txt", atomically: true, encoding: .utf8)
    try "staged\n".write(toFile: repo + "/s.txt", atomically: true, encoding: .utf8)
    try Git.run(["add", "s.txt"], cwd: repo, remotes: .none)
    try Git.run(["rm", "-q", "--cached", "f.txt"], cwd: repo, remotes: .none)
    try FileManager.default.removeItem(atPath: repo + "/f.txt")
    try Git.commit(repo, files: ["new.txt", "f.txt"], message: "one", remotes: .none)
    let took = try Git.run(["show", "--name-status", "--format=", "HEAD"], cwd: repo, remotes: .none)
    #expect(took.contains("A\tnew.txt") && took.contains("D\tf.txt") && !took.contains("s.txt"))
    #expect(try Git.run(["diff", "--cached", "--name-only"], cwd: repo, remotes: .none).contains("s.txt"))

    // Undone, the commit's changes are staged again; with another commit since, nothing is undone.
    let head = try Git.line(["rev-parse", "HEAD"], cwd: repo, remotes: .none)
    try Git.commit(repo, files: ["s.txt"], message: "two", remotes: .none)
    #expect(throws: GitError.self) { try Git.undoCommits(repo, head: head, count: 1, remotes: .none) }
    let two = try Git.line(["rev-parse", "HEAD"], cwd: repo, remotes: .none)
    try Git.undoCommits(repo, head: two, count: 2, remotes: .none)
    #expect(try Git.line(["log", "--format=%s"], cwd: repo, remotes: .none) == "init")
    let staged = try Git.run(["diff", "--cached", "--name-only"], cwd: repo, remotes: .none)
    #expect(staged.contains("new.txt") && staged.contains("s.txt") && staged.contains("f.txt"))
}
