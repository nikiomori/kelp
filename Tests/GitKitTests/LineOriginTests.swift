import Foundation
import TestSupport
import Testing

@testable import Core
@testable import GitKit

/// Each line goes to what changed it last: a turn (by its snapshots), the folder before any turn (nobody yet), or a real
/// commit; with no turns, plain blame of the folder.
@Test func aLineIsTracedToTheTurnThatChangedIt() throws {
    let d = tmp().path
    func write(_ text: String) throws { try text.write(toFile: d + "/a.txt", atomically: true, encoding: .utf8) }
    try Git.run(["init", "-q", "-b", "main"], cwd: d, remotes: .none)
    try write("1\n2\n3\n4\n")
    try Git.run(["add", "."], cwd: d, remotes: .none)
    try Git.run(["-c", "user.name=Ann", "-c", "user.email=a@x", "commit", "-qm", "init"], cwd: d, remotes: .none)
    let head = try #require(try Git.head(d, remotes: .none))
    func origin(_ line: Int, _ steps: [(tree: String, author: String, message: String)]) throws -> Git.LineBlame? {
        try Git.lineOrigin(d, file: "a.txt", line: line, steps: steps, remotes: .none)
    }
    try write("one\n2\n3\n4\n")   // before any turn
    #expect(try origin(1, [])?.commit == nil)
    let plain = try origin(2, [])
    #expect(plain?.commit == head && plain?.summary == "init")
    let first = try Git.snapshotTree(d, remotes: .none)
    try write("one\ntwo\n3\n4\n")   // the first turn
    let second = try Git.snapshotTree(d, remotes: .none)
    try write("one\ntwo\nthree\n4\n")   // the second, still going
    let steps = [
        (tree: first, author: "Claude Code", message: "fix two"), (tree: second, author: "Codex", message: "fix three")
    ]
    let one = try #require(try origin(1, steps)), two = try #require(try origin(2, steps))
    let three = try #require(try origin(3, steps)), four = try #require(try origin(4, steps))
    #expect(one.commit == nil && one.step == nil)
    #expect(two.step == 0 && two.author == "Claude Code" && two.summary == "fix two" && two.commit != nil)
    #expect(three.step == 1 && three.author == "Codex")
    #expect(four.step == nil && four.commit == head)
    #expect(try origin(9, steps) == nil, "no such line")
    #expect(try Git.lineOrigin(d, file: "none.txt", line: 1, steps: steps, remotes: .none) == nil)
    #expect(try Git.head(d, remotes: .none) == head, "no ref moved")
    #expect(try Git.run(["status", "--porcelain"], cwd: d, remotes: .none) == " M a.txt\n", "the index untouched")
}
