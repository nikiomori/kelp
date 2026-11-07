import Foundation
import TestSupport
import Testing

@testable import Core
@testable import GitKit

@Test func unsyncedListsWhatAPushSendsAndAPullBrings() throws {
    let repo = try tempRepo()
    func commit(_ dir: String, _ file: String, _ subject: String) throws {
        try "\(subject)\n".write(toFile: dir + "/" + file, atomically: true, encoding: .utf8)
        try Git.run(["add", file], cwd: dir)
        try Git.run(["commit", "-q", "--author=Ada <ada@example.com>", "-m", subject], cwd: dir)
    }
    #expect(try Git.unsynced(repo) == Unsynced(outgoing: [], incoming: []))   // no remote branch: a push has nowhere to land
    let bare = tmp().path
    try Git.run(["init", "-q", "--bare", "-b", "main"], cwd: bare)
    try Git.run(["remote", "add", "origin", bare], cwd: repo)
    try Git.run(["push", "-q", "-u", "origin", "main"], cwd: repo)
    #expect(try Git.unsynced(repo) == Unsynced(outgoing: [], incoming: []))
    try Git.run(["switch", "-q", "-c", "feature"], cwd: repo)
    try commit(repo, "a.txt", "never pushed")
    #expect(try Git.unsynced(repo).outgoing.map(\.subject) == ["never pushed"])   // no upstream: what no remote branch has
    #expect(try Git.branches(repo).ahead == 1)
    try Git.run(["switch", "-q", "main"], cwd: repo)
    // Two more here, two there (pushed from a second clone, fetched here).
    try commit(repo, "b.txt", "mine 1")
    try commit(repo, "c.txt", "mine 2")
    let other = tmp().path
    try Git.run(["clone", "-q", bare, other], cwd: NSTemporaryDirectory())
    try commit(other, "d.txt", "theirs 1")
    try commit(other, "e.txt", "theirs 2")
    try Git.run(["push", "-q"], cwd: other)
    try Git.remote(repo, .fetch)
    let u = try Git.unsynced(repo, limit: 1)
    #expect(u.outgoing.map(\.subject) == ["mine 2"] && u.incoming.map(\.subject) == ["theirs 2"])   // newest first, cut at the limit
    #expect(u.outgoing.first?.author == "Ada" && (u.outgoing.first?.date ?? 0) > 1_000_000_000)
    let b = try Git.branches(repo)
    #expect(b.ahead == 2 && b.behind == 2)   // the counts the chip shows are the lists' lengths
    #expect(try Git.unsynced(repo, limit: 9).incoming.count == 2)
    // Diverged and nothing configured: the pull merges instead of refusing; the commits it brought are no longer incoming.
    try Git.remote(repo, .pull)
    let after = try Git.branches(repo)
    #expect(after.behind == 0 && after.ahead == 3)   // mine 1, mine 2 and the merge
    #expect(try Git.unsynced(repo).incoming.isEmpty)
}
