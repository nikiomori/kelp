import Foundation
import Testing
import Core
import TestSupport
@testable import GitKit

/// A line that starts with a combining mark: with its "+" it's one Character, and it used to fall out of the hunk.
@Test func aLineStartingWithACombiningMarkStaysInItsHunk() throws {
    let d = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -0,0 +1 @@\n+\u{0301}x\n"
    let lines = try #require(Git.parseDiff(d).first?.hunks.first?.lines)
    #expect(lines.count == 1 && lines[0].kind == .add && lines[0].text == "\u{0301}x")
}

/// Hiding whitespace changes leaves out lines that only moved their spaces, and files with nothing else changed.
@Test func hidingWhitespaceLeavesOutSpaceOnlyChanges() throws {
    let repo = try tempRepo()
    try "a\nb\nc\n".write(toFile: repo + "/g.txt", atomically: true, encoding: .utf8)
    try Git.run(["add", "g.txt"], cwd: repo); try Git.run(["commit", "-qm", "g"], cwd: repo)
    try "a  \nb\nc\nd\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)   // a space and a real line
    try "  a\nb\nc\n".write(toFile: repo + "/g.txt", atomically: true, encoding: .utf8)      // a space only
    #expect(try Git.diff(repo, source: .allUncommitted).map(\.path) == ["f.txt", "g.txt", ".env"])
    let hidden = try Git.diff(repo, source: .allUncommitted, ignoreSpace: true)
    #expect(hidden.map(\.path) == ["f.txt", ".env"])   // .env: untracked, all of it new
    #expect(hidden.first.map { ($0.additions, $0.deletions) } ?? (0, 0) == (1, 0))
}

/// A cloned path is the worktree's own copy: a change there leaves the main checkout's alone; a path outside is never cloned.
@Test func clonedPathsAreTheWorktreesOwn() throws {
    let repo = try tempRepo(), wt = tmp().path
    try FileManager.default.createDirectory(atPath: repo + "/node_modules/pkg", withIntermediateDirectories: true)
    try "v1\n".write(toFile: repo + "/node_modules/pkg/index.js", atomically: true, encoding: .utf8)
    Git.cloneShared(["node_modules", "../escape"], repo: repo, worktree: wt)
    #expect(try String(contentsOfFile: wt + "/node_modules/pkg/index.js", encoding: .utf8) == "v1\n")
    try "v2\n".write(toFile: wt + "/node_modules/pkg/index.js", atomically: true, encoding: .utf8)
    #expect(try String(contentsOfFile: repo + "/node_modules/pkg/index.js", encoding: .utf8) == "v1\n")
    #expect(!FileManager.default.fileExists(atPath: wt + "/../escape"))
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: wt + "/node_modules")) == nil)   // a copy, not a link
}
