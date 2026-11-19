import Core
import Foundation
import GitKit
import Testing

@testable import Daemon

/// A remote project's worktree, removed: what git doesn't see in it (an ignored .env) is moved aside on the host, not
/// deleted for good, as a local one goes to the Trash.
@Test func aRemoteWorktreesIgnoredFilesAreKeptOnTheHost() async throws {
    _ = localSSH
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let there = try makeRepo()
    let repo: Repo = try await c.call("repo.addRemote", .obj(["host": "box", "path": .string(there)]), as: Repo.self)
    let wt = try remoteWorktree(d, repo, "aside")
    try ".env.local\n".write(toFile: there + "/.git/info/exclude", atomically: true, encoding: .utf8)
    let secret = "SECRET=\(UUID())\n"   // this test's own, among every test's in the Trash
    try secret.write(toFile: wt.path + "/.env.local", atomically: true, encoding: .utf8)
    _ = try await c.call(WorktreeRemove(id: wt.id, force: true, dropCommits: true))
    // Its folder was looked for on the host (here the same disk, so only the ssh log tells), not on this Mac.
    let sshLog = URL(fileURLWithPath: localSSH).deletingLastPathComponent().appendingPathComponent("ssh.log").path
    let sent = (try? String(contentsOfFile: sshLog, encoding: .utf8)) ?? ""
    #expect(sent.split(separator: "\n").contains { $0.hasPrefix("sh -c '[ -e ") && $0.contains(wt.path) })
    #expect(inTheTrash(".env.local", holding: secret))
}

/// A remote project's locked worktree (`git worktree lock`) isn't moved aside on the host: it's kept, as a local one.
@Test func aRemoteLockedWorktreeStays() async throws {
    _ = localSSH
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let there = try makeRepo()
    let repo: Repo = try await c.call("repo.addRemote", .obj(["host": "box", "path": .string(there)]), as: Repo.self)
    let wt = try remoteWorktree(d, repo, "kept")
    try Git.run(["worktree", "lock", wt.path], cwd: there, remotes: .none)
    await expectRefusal(says: "is locked") {
        try await c.call(WorktreeRemove(id: wt.id, force: true, dropCommits: true))
    }
    #expect(FileManager.default.fileExists(atPath: wt.path))
}

/// A remote project's worktree as an older Kelp made it (a new one has a stand-in here,
/// `aRemoteProjectsBranchGetsAWorktreeOnItsHost`): on the host, at the path its record names.
private func remoteWorktree(_ d: Daemon, _ repo: Repo, _ branch: String) throws -> Worktree {
    let path = try Git.addWorktree(
        repo: repo.path, branch: branch, base: "main", into: Workspaces.worktreesDir(d.root, repo),
        copyFiles: [], remotes: d.workspaces.remotes)
    let w = Worktree(repoId: repo.id, branch: branch, path: path, note: "", base: "main")
    try d.store.save(w)
    return w
}
