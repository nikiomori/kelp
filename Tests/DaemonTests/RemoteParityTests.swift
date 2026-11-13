import Core
import Foundation
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
