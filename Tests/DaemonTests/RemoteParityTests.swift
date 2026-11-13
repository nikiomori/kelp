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

/// A routine of a remote project doesn't leave its agent waiting for a password nobody sees: the host is connected
/// first without one, and when that fails the run says why at once.
@Test func aRemoteRoutineSaysWhyItsHostWasntReached() async throws {
    _ = localSSH
    let (d, c, _) = try daemon(agents: [AgentManifest(id: "bot", name: "Bot", command: "/bin/cat")])
    defer { d.stop() }
    let host = "flaky-\(UUID().uuidString.prefix(6))"
    let (repo, _, _) = try await remoteProject(c, host: host)
    let shim = URL(fileURLWithPath: localSSH).deletingLastPathComponent()
    for mark in ["down-", "unreachable-"] {
        FileManager.default.createFile(atPath: shim.appendingPathComponent(mark + host).path, contents: nil)
    }
    defer {
        for mark in ["down-", "unreachable-"] {
            try? FileManager.default.removeItem(at: shim.appendingPathComponent(mark + host))
        }
    }
    let routine = try await c.call(
        RoutineSet(routine: Routine(name: "Nightly", repoId: repo.id, agent: "bot", prompt: "x")))
    await #expect {
        try await c.call(RoutineRun(id: routine.id))
    } throws: { error in
        (error as? RPCError)?.message == "Can't reach \(host): ssh: Could not resolve hostname \(host)"
    }
}

/// With terminals kept in tmux, a remote project's terminal is kept in a tmux session of its own on the host, as its
/// agents are: a dropped connection leaves it there to come back to.
@Test func aRemoteTerminalIsKeptInTmuxOnItsHost() async throws {
    _ = localSSH
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let (_, workspace, _) = try await remoteProject(c)
    _ = try await c.call(SettingsSet(key: SettingKeys.tmux.key, value: true))
    let terminal = try await c.call(SessionCreate(worktreeId: workspace.id))
    #expect(terminal.tmux.map(Tmux.isOwn) == true && Tmux.session(terminal.argv) == nil)
    _ = try await c.call(SessionKill(id: terminal.id))
}

/// A remote project's files are made, renamed, copied and thrown away on its host as here: a taken name is never written
/// over, a copy gets a free name, and what's trashed comes back by moving it again (Undo).
@Test func aRemoteProjectsFilesAreChangedOnItsHost() async throws {
    _ = localSSH
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let (repo, _, there) = try await remoteProject(c)
    let here = repo.path, fm = FileManager.default
    let made = try await c.call(FilesCreate(path: here + "/docs/a b.md", text: "hi\n"))
    #expect(made == here + "/docs/a b.md")
    #expect(try String(contentsOfFile: there + "/docs/a b.md", encoding: .utf8) == "hi\n")
    await #expect(throws: RPCError.self) { try await c.call(FilesCreate(path: made, text: "over")) }
    #expect(try String(contentsOfFile: there + "/docs/a b.md", encoding: .utf8) == "hi\n", "not written over")
    #expect(try await c.call(FilesCreate(path: made, text: "x", unique: true)) == here + "/docs/a b 2.md")
    #expect(try await c.call(FilesCreate(path: here + "/src", folder: true)) == here + "/src")

    let moved = try await c.call(FilesMove(pairs: [FileMove(from: made, to: here + "/src/a b.md")]))
    #expect(
        moved.error == nil && fm.fileExists(atPath: there + "/src/a b.md")
            && !fm.fileExists(atPath: there + "/docs/a b.md"))
    let copied = try await c.call(FilesCopy(paths: [here + "/src/a b.md"], into: here + "/src"))
    #expect(copied.made == [here + "/src/a b copy.md"])

    let trashed = try await c.call(FilesTrash(paths: [here + "/src/a b copy.md"]))
    let gone = try #require(trashed.done.first)
    #expect(!fm.fileExists(atPath: there + "/src/a b copy.md") && gone.to.hasPrefix(here + "/.git/kelp-trash/"))
    #expect(try Git.run(["status", "--porcelain"], cwd: there, remotes: .none).contains("kelp-trash") == false)
    _ = try await c.call(FilesMove(pairs: [FileMove(from: gone.to, to: gone.from)]))   // Undo
    #expect(fm.fileExists(atPath: there + "/src/a b copy.md"))
}

/// A remote chat is forked and handed off on its host, as here: the fork goes on from its conversation there, and the
/// brief the next agent reads is copied to the host.
@Test func aRemoteChatIsForkedAndHandedOffOnItsHost() async throws {
    _ = localSSH
    var claude = AgentManifest(id: "claude", name: "Claude Code", command: "/bin/bash", args: ["-c", "sleep 30", "x"])
    claude.sessionIdFlag = "--session-id"
    claude.resumeIdFlag = "--resume"
    claude.transcript = .claude
    let (d, c, _) = try daemon(agents: [claude])
    defer { d.stop() }
    let host = tmp()
    d.agentUsage.conversations.hostClaude.withLock { $0 = ShellQuote.word(host.path) }
    let (_, workspace, there) = try await remoteProject(c)
    let session = try await c.call(SessionCreate(worktreeId: workspace.id, agent: "claude"))
    let folder = host.appendingPathComponent(
        "projects/" + (try #require(Paths.real(there))).replacing(/[^A-Za-z0-9]/, with: "-"))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try #"""
    {"type":"user","message":{"role":"user","content":"Make the loop faster"}}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done: it caches now."}]}}
    """#.write(to: folder.appendingPathComponent(session.id.lowercased() + ".jsonl"), atomically: true, encoding: .utf8)

    let fork = try await c.call(SessionFork(id: session.id))
    #expect(fork.argv.contains("--fork-session") && fork.argv.contains(session.id.lowercased()))
    let next = try await c.call(SessionHandoff(id: session.id, agent: "claude", full: false, prompt: "Go on."))
    let brief = try String(
        contentsOfFile: try #require(Paths.real(there)) + "/.git/kelp-handoff/\(session.id).md", encoding: .utf8)
    #expect(brief.contains("Make the loop faster") && brief.contains("it caches now"))
    for id in [session.id, fork.id, next.id] { _ = try await c.call(SessionKill(id: id)) }
}

/// A remote agent gets its Environment settings on the host, as here.
@Test func aRemoteAgentGetsItsEnvironment() async throws {
    _ = localSSH
    let out = tmp().appendingPathComponent("env")
    let agent = AgentManifest(
        id: "bot", name: "Bot", command: "/bin/sh",
        args: ["-c", #"echo "$GREETING $COLORTERM" > \#(out.path); sleep 30"#],
        env: ["GREETING": "hello there"])
    let (d, c, _) = try daemon(agents: [agent])
    defer { d.stop() }
    let (_, workspace, _) = try await remoteProject(c)
    let session = try await c.call(SessionCreate(worktreeId: workspace.id, agent: "bot"))
    #expect(try await waitFor(10) { (try? String(contentsOf: out, encoding: .utf8)) == "hello there truecolor\n" })
    _ = try await c.call(SessionKill(id: session.id))
}

/// An open file of a remote project follows its host: an agent's edit there comes as a new version (its digest, as
/// files.read says it), and a file gone as none.
@Test func aRemoteFilesVersionFollowsItsHost() async throws {
    _ = localSSH
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let (repo, _, there) = try await remoteProject(c)
    let path = repo.path + "/a.txt", read = d.topic(Watches.Key(topic: .file, key: path)).read
    func stamp() async throws -> FileStamp?? {   // nil: nothing read; .some(nil): gone
        guard let line = await read(false).0 else { return nil }
        return .some(try JSONDecoder().decode(JSONValue.self, from: line)["params"]?["stamp"]?.string)
    }
    #expect(try await stamp() == .some(try await c.call(FilesRead(path: path)).stamp))
    try "an agent's\n".write(toFile: there + "/a.txt", atomically: true, encoding: .utf8)
    #expect(try await stamp() == .some(FileService.digest(Data("an agent's\n".utf8))))
    try FileManager.default.removeItem(atPath: there + "/a.txt")
    #expect(try await stamp() == .some(nil))
}

/// A remote chat's context meter reads the end of its conversation on the host, over the connection its tab has open.
@Test func aRemoteChatsContextIsReadOnItsHost() async throws {
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
    let folder = host.appendingPathComponent(
        "projects/" + (try #require(Paths.real(there))).replacing(/[^A-Za-z0-9]/, with: "-"))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try
        #"{"type":"assistant","message":{"model":"m","usage":{"input_tokens":2,"cache_read_input_tokens":250000,"cache_creation_input_tokens":8,"output_tokens":90}}}"#
        .write(to: folder.appendingPathComponent(session.id.lowercased() + ".jsonl"), atomically: true, encoding: .utf8)
    let usage = try await c.call(SessionContextWindow(id: session.id))
    #expect(usage?.used == 250_010)
    _ = try await c.call(SessionKill(id: session.id))
}

/// A host's key as the trust question shows it: its fingerprint and kind, as ssh-keygen says them.
@Test func aHostsKeyIsShownAsSshShowsIt() throws {
    let dir = tmp(), key = dir.appendingPathComponent("k")
    _ = try Subprocess.output(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key.path], cwd: "/")
    let pub = try String(contentsOf: dir.appendingPathComponent("k.pub"), encoding: .utf8)
        .split(separator: " ").prefix(2).joined(separator: " ")
    let shown = String(
        decoding: try Subprocess.output(["/usr/bin/ssh-keygen", "-l", "-f", key.path + ".pub"], cwd: "/"), as: UTF8.self
    )
    let found = try #require(keyFingerprint(["[box]:2222 " + pub]))
    #expect(shown.contains(found.fingerprint) && found.kind == "ED25519")
}

/// What isn't a host, as ssh would read an option, has no key to show or trust.
@Test func aHostKeyIsAskedOnlyOfAHost() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    #expect(try await c.call(RemoteHostKey(host: "-oProxyCommand=x")) == nil)
    await #expect(throws: RPCError.self) {
        try await c.call(RemoteTrustHost(host: "-oProxyCommand=x", fingerprint: "SHA256:x"))
    }
}

/// An account profile is a folder on this Mac: a chat on a host is refused one, saying so, rather than signed in to the
/// host's own account under the profile's name.
@Test func aRemoteChatTakesNoAccountProfile() async throws {
    _ = localSSH
    let (d, c, _) = try daemon(agents: [AgentManifest(id: "bot", name: "Bot", command: "/bin/cat")])
    defer { d.stop() }
    let (_, workspace, _) = try await remoteProject(c)
    await #expect {
        try await c.call(SessionCreate(worktreeId: workspace.id, agent: "bot", profile: "work"))
    } throws: { ($0 as? RPCError)?.message.contains("Account profiles are for agents on this Mac") == true }
}

/// An extension's command in a remote project runs here from the home folder, never in the project's folder here (its
/// git would walk up into another repository), and is told where the project is.
@Test func anExtensionsCommandIsToldWhereARemoteProjectIs() async throws {
    _ = localSSH
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let (repo, _, there) = try await remoteProject(c)
    let ran = try await c.call(
        ProcessRun(
            argv: ["/bin/sh", "-c", #"pwd; echo "$KELP_REMOTE_HOST $KELP_REMOTE_PATH""#], cwd: repo.path + "/src"))
    let real = try #require(Paths.real(there))
    #expect(ran.stdout == (Paths.real(NSHomeDirectory()) ?? NSHomeDirectory()) + "\nbox \(real)/src\n")
    #expect(!ran.stdout.contains(repo.path))
}
