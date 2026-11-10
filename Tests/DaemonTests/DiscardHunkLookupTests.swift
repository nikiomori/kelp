import Core
import Foundation
import GitKit
import Testing

@testable import Daemon

/// A file's second change is discarded by what it shows (the change bars send no number), as `git.hunk` finds one; the
/// first is left alone, and a hunk no longer there is refused.
@Test func theSecondHunkOfAFileIsDiscardedByItsFingerprint() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await workspace(w, "second-hunk")
    let lines = (1...20).map { "line \($0)" }
    func text(_ changes: [Int: String]) -> String {
        lines.enumerated().map { changes[$0.offset + 1] ?? $0.element }.joined(separator: "\n") + "\n"
    }
    try text([:]).write(toFile: wt.path + "/f.txt", atomically: true, encoding: .utf8)
    try Git.run(["add", "f.txt"], cwd: wt.path, remotes: .none)
    try Git.run(["commit", "-qm", "twenty lines"], cwd: wt.path, remotes: .none)
    try text([1: "first", 20: "second"]).write(toFile: wt.path + "/f.txt", atomically: true, encoding: .utf8)
    let hunks = try #require(try Git.diff(wt.path, source: .unstaged, file: "f.txt", remotes: .none).first?.hunks)
    try #require(hunks.count == 2)
    let second = hunks[1]
    _ = try await w.c.call(
        GitDiscardHunk(id: wt.id, file: "f.txt", hunk: 0, header: second.header, fingerprint: second.fingerprint))
    #expect(try String(contentsOfFile: wt.path + "/f.txt", encoding: .utf8) == text([1: "first"]))
    await #expect(throws: (any Error).self) {   // gone now: nothing else is taken in its place
        _ = try await w.c.call(
            GitDiscardHunk(id: wt.id, file: "f.txt", hunk: 0, header: second.header, fingerprint: second.fingerprint))
    }
    #expect(try String(contentsOfFile: wt.path + "/f.txt", encoding: .utf8) == text([1: "first"]))
}
