import Agents
import Core
import Foundation
import GitKit
import Testing

@testable import Daemon

/// A remote project on a stand-in host (`localSSH`: the host is this Mac, touched before the daemon starts), its
/// workspace, and its folder there.
func remoteProject(_ c: RPCClient, host: String = "box") async throws -> (
    repo: Repo, workspace: Worktree, there: String
) {
    _ = localSSH
    let there = try makeRepo()
    let repo: Repo = try await c.call(
        "repo.addRemote", .obj(["host": .string(host), "path": .string(there)]), as: Repo.self)
    let workspace = try #require(try await c.call("worktree.list", as: [Worktree].self).first { $0.repoId == repo.id })
    return (repo, workspace, there)
}

/// A remote project's commands are its .kelp.yaml on the host, asked for when someone looks at them, and trusted as
/// shown, as here.
@Test func aRemoteProjectsCommandsAreItsHostsKelpYaml() async throws {
    _ = localSSH
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let (_, workspace, there) = try await remoteProject(c)
    try "script.hello: echo hi\n".write(toFile: there + "/.kelp.yaml", atomically: true, encoding: .utf8)
    let shown = try await c.call(ScriptsList(worktreeId: workspace.id))
    #expect(shown.scripts == [.init(name: "hello", command: "echo hi")])
    _ = try await trustAsShown(c, .string(workspace.id))
}

/// A remote Claude Code's chat comes back with its conversation once the host has it; with nothing typed yet it starts
/// under its id again rather than stop at "No conversation found".
@Test func aRemoteChatResumesOnlyAConversationThere() async throws {
    _ = localSSH
    var claude = AgentManifest(id: "claude", name: "Claude Code", command: "/bin/bash", args: ["-c", "sleep 30", "x"])
    claude.sessionIdFlag = "--session-id"
    claude.resumeIdFlag = "--resume"
    let (d, c, _) = try daemon(agents: [claude])
    defer { d.stop() }
    let host = tmp()
    d.agentUsage.conversations.hostClaude.withLock { $0 = ShellQuote.word(host.path) }
    let (_, workspace, there) = try await remoteProject(c)
    let session = try await c.call(SessionCreate(worktreeId: workspace.id, agent: "claude"))
    let manifest = try d.sessions.setup.manifest("claude", command: nil, fallbackArgv: session.argv)
    #expect(!d.sessions.setup.resumeArgv(session, manifest).contains("--resume"))
    let folder = host.appendingPathComponent(
        "projects/" + (try #require(Paths.real(there))).replacing(/[^A-Za-z0-9]/, with: "-"))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "{}\n".write(
        to: folder.appendingPathComponent(session.id.lowercased() + ".jsonl"), atomically: true, encoding: .utf8)
    #expect(d.sessions.setup.resumeArgv(session, manifest).contains("--resume"))
    _ = try await c.call(SessionKill(id: session.id))
}

/// A remote project's workspace follows the branch checked out on its host, as its git is read (no file events there).
@Test func aRemoteWorkspaceFollowsItsHostsBranch() async throws {
    _ = localSSH
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let (_, workspace, there) = try await remoteProject(c)
    try Git.run(["switch", "-q", "-c", "feature"], cwd: there, remotes: .none)
    _ = await d.topic(Watches.Key(topic: .git, key: workspace.id)).read(false)
    #expect(try d.store.worktree(workspace.id)?.branch == "feature")
}
