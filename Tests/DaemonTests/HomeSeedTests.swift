import Foundation
import Testing
import Core
import Agents
import AgentData
import GRDB
import TestSupport
@testable import Daemon

private func write(_ text: String, _ url: URL) throws {
    try Paths.ensure(url.deletingLastPathComponent())
    try Data(text.utf8).write(to: url)
}

/// A build with its own home starts with Kelp's projects and agents, and nothing Kelp runs is touched or doubled.
@Test func aHomeStartsAsACopyOfKelps() throws {
    let stable = tmp().appendingPathComponent(".kelp"), home = tmp().appendingPathComponent(".kelp-beta")
    func kelp(_ path: String) -> String { stable.appendingPathComponent(path).path }
    for f in ["settings.json", "hooks-claude.json", "history/1.log", "remote/host/app/.kelp-remote", "scratch/note"] {
        try write(f, stable.appendingPathComponent(f))
    }
    let kept = try Store(path: kelp("kelp.sqlite"))
    let project = Repo(name: "app", path: "/work/app"), standIn = Repo(name: "there", path: kelp("remote/host/app")), scratch = Repo(name: "Scratch", path: kelp("scratch"))
    for r in [project, standIn, scratch] { try kept.save(r) }
    let worktree = Worktree(repoId: project.id, branch: "f", path: kelp("worktrees/app/f"))   // git knows it by this path
    try kept.save(worktree)
    try kept.save(Routine(id: "r", name: "Morning", repoId: project.id, agent: "claude", prompt: "x"))
    let claude = ["claude", "--settings", kelp("hooks-claude.json"), "--plugin-dir", kelp("agent-skills")]
    func session(_ cwd: String, _ agent: String, _ argv: [String], _ status: AgentStatus = .working, tmux: String? = nil) throws -> Session {
        var s = Session(cwd: cwd, command: agent, agent: agent, argv: argv)
        s.status = status; s.tmux = tmux
        return try kept.save(s)
    }
    let live = try session("/work/app", "claude", claude + ["--session-id", "abc"])
    let paused = try session("/work/app", "claude", ["claude", "--resume", "def"], .hibernated)
    let inScratch = try session(kelp("scratch"), "claude", ["claude", "--session-id", "ghi"], .idle)
    let codex = try session("/work/app", "codex", ["codex"])
    let onHost = try session(kelp("remote/host/app"), "claude", ["claude"], tmux: "kelp-1")
    let remoteShell = try session(kelp("remote/host/app"), "shell", ["zsh"])
    let ended = try session("/work/app", "claude", ["claude", "--session-id", "jkl"], .exited)
    let unpinned = try session("/work/app", "claude", ["claude"])

    HomeSeed.fill(home, from: stable)

    let copy = try Store(path: home.appendingPathComponent("kelp.sqlite").path)
    #expect(try copy.repo(project.id)?.path == "/work/app")
    #expect(try copy.repo(standIn.id)?.path == home.path + "/remote/host/app")
    #expect(try copy.repo(scratch.id)?.path == home.path + "/scratch")
    #expect(try copy.worktree(worktree.id)?.path == kelp("worktrees/app/f"))
    #expect(try copy.db.read { try Routine.fetchOne($0, key: "r") }?.enabled == false)
    let forked = try #require(try copy.session(live.id))
    #expect(forked.status == .working)   // start() pauses it
    #expect(forked.argv == ["claude", "--settings", home.path + "/hooks-claude.json", "--plugin-dir", home.path + "/agent-skills", "--resume", "abc", "--fork-session"])
    #expect(try copy.session(paused.id)?.argv == ["claude", "--resume", "def", "--fork-session"])
    // Claude finds a conversation by its folder: a scratch agent stays in Kelp's, a fork like the others.
    #expect(try copy.session(inScratch.id)?.argv == ["claude", "--resume", "ghi", "--fork-session"])
    #expect(try copy.session(inScratch.id)?.cwd == kelp("scratch"))
    #expect(try copy.session(codex.id)?.status == .exited)
    #expect(try copy.session(onHost.id) == nil)   // closing it here would end the tmux session it runs in there
    #expect(try copy.session(remoteShell.id)?.status == .exited)
    #expect(try copy.session(remoteShell.id)?.cwd == home.path + "/remote/host/app")
    #expect(try copy.session(ended.id)?.argv == ["claude", "--session-id", "jkl"])
    #expect(try copy.session(unpinned.id)?.status == .exited)   // no id: it couldn't follow its fork

    for f in ["settings.json", "hooks-claude.json", "history/1.log", "remote/host/app/.kelp-remote", "scratch/note"] {
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(f).path), "\(f)")
    }
    for f in ["kelp.sqlite.seed", "kelp.sqlite.seed-wal", "kelp.sqlite.seed-shm"] {
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(f).path), "\(f)")
    }
    #expect(try kept.session(live.id)?.argv == claude + ["--session-id", "abc"])
    #expect(try kept.session(live.id)?.status == .working)
    #expect(try kept.repo(standIn.id)?.path == kelp("remote/host/app"))
}

/// Once it has its own database, the home is its own: no later start copies anything over it.
@Test func aHomeIsFilledOnce() throws {
    let stable = tmp(), home = tmp()
    try write("kelp's", stable.appendingPathComponent("settings.json"))
    _ = try Store(path: stable.appendingPathComponent("kelp.sqlite").path)
    try write("its own", home.appendingPathComponent("settings.json"))   // kept: a home is never overwritten
    HomeSeed.fill(home, from: stable)
    #expect(try String(contentsOf: home.appendingPathComponent("settings.json"), encoding: .utf8) == "its own")

    let own = try Store(path: home.appendingPathComponent("kelp.sqlite").path)
    try own.save(Repo(name: "here", path: "/here"))
    HomeSeed.fill(home, from: stable)
    #expect(try own.repos().map(\.name) == ["here"])
}

/// No Kelp to copy: an empty home, as for anyone who starts with Beta.
@Test func withoutKelpAHomeStaysEmpty() {
    let stable = tmp(), home = tmp()
    HomeSeed.fill(home, from: stable)
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("kelp.sqlite").path))
}

/// Tests and snapshots pick their home with KELP_HOME: they never get someone's real projects.
@Test func aHomePickedByKelpHomeIsntFilled() {
    #expect(Paths.seed == nil)
}

/// A tab open with nothing typed has no conversation on disk, and --resume of one fails: it starts a new one instead.
@Test func aForkOfNoConversationStartsANewOne() async throws {
    let w = try await world(); defer { w.d.stop() }
    let claude = try #require(AgentManifest.presets.first { $0.id == "claude" })
    let cwd = tmp().path, sessions = w.d.sessions
    let fork = Session(cwd: cwd, command: "claude", agent: "claude", argv: ["claude", "--resume", "abc", "--fork-session"])
    let new = sessions.resumeArgv(fork, claude)
    #expect(new.count == 3 && new[1] == "--session-id" && new[2] != "abc")

    let transcript = ClaudeHistory.folder(cwd: cwd, root: sessions.claudeProjects(fork)).appendingPathComponent("abc.jsonl")
    try write(#"{"type":"user","message":{"role":"user","content":"hi"},"cwd":"\#(cwd)","sessionId":"abc","timestamp":"2026-10-30T10:00:00Z"}"# + "\n", transcript)
    #expect(sessions.resumeArgv(fork, claude) == fork.argv)
}
