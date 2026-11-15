import Foundation
import TestSupport
import Testing

@testable import Core
@testable import GitKit

/// A turn's snapshot and what was staged, from one copy of the index: the same trees `snapshotTree` and `indexTree` write
/// apart, with staged, unstaged and new files (a secret left out), and the real index untouched.
@Test func aTurnsSnapshotIsTheTreeAndTheStagedOneAtOnce() throws {
    let repo = try tempRepo()
    try "staged\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
    try Git.run(["add", "f.txt"], cwd: repo, remotes: .none)
    try "staged, then changed\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
    try "new\n".write(toFile: repo + "/new.txt", atomically: true, encoding: .utf8)
    try "key\n".write(toFile: repo + "/id_rsa", atomically: true, encoding: .utf8)
    let cached = try Git.run(["diff", "--cached", "--name-only"], cwd: repo, remotes: .none)

    let turn = try Git.turnSnapshot(repo, remotes: .none)
    #expect(turn.tree == (try Git.snapshotTree(repo, remotes: .none)))
    let staged = try Git.indexTree(repo, remotes: .none)
    #expect(turn.staged == staged && staged != nil && staged != turn.tree)
    let files = try Git.run(["ls-tree", "-r", "--name-only", turn.tree], cwd: repo, remotes: .none)
    #expect(files.contains("new.txt") && !files.contains("id_rsa") && !files.contains(".env"))
    #expect(
        try Git.run(["diff", "--cached", "--name-only"], cwd: repo, remotes: .none) == cached, "its index untouched")
}

/// Amid unresolved conflicts git writes no tree of what's staged: none is kept, and the snapshot is still taken.
@Test func aTurnBegunAmidConflictsKeepsNoStagedTree() throws {
    let repo = try tempRepo()
    try Git.run(["switch", "-qc", "other"], cwd: repo, remotes: .none)
    try "theirs\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
    try Git.run(["commit", "-qam", "theirs"], cwd: repo, remotes: .none)
    try Git.run(["switch", "-q", "main"], cwd: repo, remotes: .none)
    try "ours\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
    try Git.run(["commit", "-qam", "ours"], cwd: repo, remotes: .none)
    _ = try? Git.run(["merge", "other"], cwd: repo, remotes: .none)
    let unmerged = try Git.run(["ls-files", "-u"], cwd: repo, remotes: .none)
    #expect(!unmerged.isEmpty)

    let turn = try Git.turnSnapshot(repo, remotes: .none)
    let staged = try Git.indexTree(repo, remotes: .none)
    #expect(turn.staged == nil && staged == nil)
    #expect(turn.tree == (try Git.snapshotTree(repo, remotes: .none)))
}

/// On a remote project's host: the same trees as here, in two runs there (the new files, then one script), where the
/// snapshot and the staged tree took four.
@Test func aRemoteTurnsSnapshotIsTwoRunsOnItsHost() throws {
    let repo = try Paths.real(tempRepo()) ?? ""
    try "staged\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
    try Git.run(["add", "f.txt"], cwd: repo, remotes: .none)
    try "new\n".write(toFile: repo + "/new.txt", atomically: true, encoding: .utf8)
    let home = tmp(), folder = home.appendingPathComponent("remote/box/app"), ssh = home.appendingPathComponent("ssh")
    let log = home.appendingPathComponent("runs")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try JSONEncoder().encode(RemoteHost(host: "box", path: repo)).write(
        to: folder.appendingPathComponent(RemoteHost.marker))
    try "#!/bin/sh\necho run >> \(log.path)\neval \"c=\\${$#}\"\nexec /bin/sh -c \"$c\"\n".write(
        to: ssh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
    let remotes = Remotes(home: home, ssh: ssh.path)

    let turn = try Git.turnSnapshot(folder.path, remotes: remotes)
    let runs = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").count
    #expect(runs == 2)
    #expect(turn.tree == (try Git.snapshotTree(repo, remotes: .none)))
    let staged = try Git.indexTree(repo, remotes: .none)
    #expect(turn.staged == staged && staged != nil)
}

/// A turn's refs are set, and the old turns' dropped, in the same git run; one already gone stops none of them.
@Test func aTurnsRefsAreSetAsOldOnesGoInOneRun() throws {
    let repo = try tempRepo()
    let head = try #require(try Git.head(repo, remotes: .none))
    try Git.setRef("refs/kelp/old", to: head, cwd: repo, remotes: .none)
    try Git.deleteRefs(["refs/kelp/old", "refs/kelp/gone"], setting: [("refs/kelp/c", head)], cwd: repo, remotes: .none)
    #expect(try Git.resolve("refs/kelp/c", cwd: repo, remotes: .none) == head)
    #expect(try Git.resolve("refs/kelp/old", cwd: repo, remotes: .none) == nil)
}
