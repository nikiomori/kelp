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
    try "SECRET=1\n".write(toFile: wt.path + "/.env.local", atomically: true, encoding: .utf8)
    _ = try await c.call(WorktreeRemove(id: wt.id, force: true, dropCommits: true))
    // Its folder was looked for on the host (here the same disk, so only the ssh log tells), not on this Mac.
    let sshLog = URL(fileURLWithPath: localSSH).deletingLastPathComponent().appendingPathComponent("ssh.log").path
    let sent = (try? String(contentsOfFile: sshLog, encoding: .utf8)) ?? ""
    #expect(sent.split(separator: "\n").contains { $0.hasPrefix("sh -c '[ -e ") && $0.contains(wt.path) })
    let trash = try #require(ProcessInfo.processInfo.environment["KELP_TRASH"])
    let kept = (FileManager.default.enumerator(atPath: trash)?.allObjects as? [String] ?? []).filter {
        $0.hasSuffix(".env.local")
    }
    #expect(!kept.isEmpty)
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
    await #expect(throws: RPCError.self) { try await c.call(WorktreeRemove(id: wt.id, force: true, dropCommits: true)) }
    #expect(FileManager.default.fileExists(atPath: wt.path))
}

/// A remote project's worktree as an older Kelp made it (new ones are refused): on the host, beside its folder.
private func remoteWorktree(_ d: Daemon, _ repo: Repo, _ branch: String) throws -> Worktree {
    let path = try Git.addWorktree(
        repo: repo.path, branch: branch, base: "main", into: Workspaces.worktreesDir(d.root, repo),
        copyFiles: [], remotes: d.workspaces.remotes)
    let w = Worktree(repoId: repo.id, branch: branch, path: path, note: "", base: "main")
    try d.store.save(w)
    return w
}

/// A remote project gets no new worktree: its git would run on this Mac, not the host.
@Test func aRemoteProjectGetsNoNewWorktree() async throws {
    _ = localSSH
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let repo = try await c.call(RepoAddRemote(host: "box", path: try makeRepo()))
    await #expect(throws: RPCError.self) { _ = try await c.call(WorktreeCreate(repoId: repo.id, branch: "x")) }
}
