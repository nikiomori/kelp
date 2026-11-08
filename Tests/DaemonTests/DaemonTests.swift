import AgentData
import Agents
import Core
import Foundation
import GitKit
@_exported import TestSupport   // tmp() and the rest, for every file of these tests
import Testing

@testable import Daemon

/// Every test that starts a daemon goes through `tmp()` (TestSupport), which isolates the whole test process first.
let testRoot = TestIsolation.root

/// `ssh` that runs the command here (the host is this Mac). One for the whole test process, made before anything reads
/// a daemon (its `Remotes` reads KELP_SSH as it starts): two tests making their own could overwrite each other's.
let localSSH: String = {
    let shim = tmp().appendingPathComponent("ssh")
    try? """
    #!/bin/sh
    while [ $# -gt 1 ]; do case "$1" in -o) shift 2;; -T|-tt|--) shift;; -O) printf '%s\\n' "$*" >> "$(dirname "$0")/ssh.log"; exit 0;; *) shift; break;; esac; done
    printf '%s\\n' "$1" >> "$(dirname "$0")/ssh.log"
    case "$1" in *cut-short*) head -c 3 | exec /bin/sh -c "$1";; esac   # a connection dropped part way through
    case "$1" in *slow-host*) if [ -e "$(dirname "$0")/slow-host" ]; then : > "$(dirname "$0")/slow-asked"; sleep 3; fi;; esac   # slow, when asked to be
    exec /bin/sh -c "$1"
    """.write(to: shim, atomically: true, encoding: .utf8)
    chmod(shim.path, 0o755)
    setenv("KELP_SSH", shim.path, 1)
    return shim.path
}()

/// What the app does: show the .kelp.yaml (scripts.list), then trust the digest of what was shown.

func trustAsShown(_ c: RPCClient, _ worktreeId: JSONValue) async throws -> JSONValue {
    _ = TestIsolation.root   // which names this process Kelp's window (KELP_APP_EXECUTABLE): only it may trust
    let shown = try await c.call("scripts.list", .obj(["worktreeId": worktreeId]))
    return try await c.call("scripts.trust", .obj(["worktreeId": worktreeId, "digest": shown["digest"] ?? .null]))
}

func makeRepo() throws -> String {
    let d = tmp().path
    try Git.run(["init", "-q", "-b", "main"], cwd: d)
    try "hello\n".write(toFile: d + "/a.txt", atomically: true, encoding: .utf8)
    try "setup: touch SETUP_RAN\n".write(toFile: d + "/.kelp.yaml", atomically: true, encoding: .utf8)
    try "SETUP_RAN\n".write(toFile: d + "/.gitignore", atomically: true, encoding: .utf8)
    try Git.run(["add", "."], cwd: d)
    try Git.run(["commit", "-qm", "init"], cwd: d)
    return d
}

/// Another client of the daemon whose home is `root` (a "restarted UI").
func client(_ root: URL) throws -> RPCClient { try RPCClient(socket: root.appendingPathComponent("kelp.sock").path) }

/// A daemon on a fresh home with `agents` in its agents folder, started, and a client of it.
func daemon(agents: [AgentManifest] = [], lspDelays: (retry: TimeInterval, idle: TimeInterval)? = nil) throws -> (
    d: Daemon, c: RPCClient, root: URL
) {
    let root = tmp(), d = try lspDelays.map { try Daemon(root: root, store: nil, lspDelays: $0) } ?? Daemon(root: root)
    if !agents.isEmpty {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("agents"), withIntermediateDirectories: true)
        for a in agents { try JSONEncoder().encode(a).write(to: root.appendingPathComponent("agents/\(a.id).json")) }
    }
    d.watches.reads.withLock { $0 = [:] }   // counted for the tests that look
    try d.start()
    return (d, try client(root), root)
}

typealias World = (d: Daemon, c: RPCClient, root: URL, repo: Repo)

/// Every status change `id` made so far has been saved and sent: what a check that nothing changed reads after.
func saved(_ w: World, _ id: String) async {
    guard let ls = w.d.sessions.existing(id) else { return }
    await withCheckedContinuation { c in ls.inOrder { c.resume() } }
}
/// `daemon(agents:)` with one project (`makeRepo`) added.
func world(agents: [AgentManifest] = []) async throws -> World {
    let (d, c, root) = try daemon(agents: agents)
    return (d, c, root, try await c.call("repo.add", .obj(["path": .string(try makeRepo())]), as: Repo.self))
}

/// The project's first workspace: its own folder.
func firstWorkspace(_ w: World) async throws -> Worktree {
    try #require(try await w.c.call("worktree.list", as: [Worktree].self).first { $0.repoId == w.repo.id })
}

/// Sessions left alone this long pause (0: never).
func hibernate(after minutes: Double, _ c: RPCClient) async throws {
    _ = try await c.call("settings.set", .obj(["key": "sessions.hibernateMinutes", "value": .double(minutes)]))
}

/// A new workspace on `branch`, its setup not run.
func workspace(_ w: World, _ branch: String) async throws -> Worktree {
    try await w.c.call(
        "worktree.create", .obj(["repoId": .string(w.repo.id), "branch": .string(branch), "setup": false]),
        as: Worktree.self)
}

/// A pull request brings code the trusted .kelp.yaml doesn't vouch for (an install script of its author's): its worktree
/// runs nothing until the user is asked.
@Test func aPullRequestRunsNothingUnasked() async throws {
    let (d, c, _, repo) = try await world()
    defer { d.stop() }
    let first = try await c.call(
        "worktree.create", .obj(["repoId": .string(repo.id), "branch": "feat/zero", "setup": false]))
    _ = try await trustAsShown(c, first["id"] ?? .null)
    let origin = tmp().path
    try Git.run(["init", "-q", "--bare", origin], cwd: repo.path)
    try Git.run(["remote", "add", "origin", origin], cwd: repo.path)
    try Git.run(["push", "-q", "origin", "main:refs/pull/5/head"], cwd: repo.path)
    let pr = try await c.call("worktree.create", .obj(["repoId": .string(repo.id), "pr": 5]))
    #expect(pr["setupNeedsTrust"]?.bool == true && pr["setupSession"] == nil && pr["branch"]?.string == "pr-5")
    // A setup runs as a session of its workspace: none was started, so none is on its way to SETUP_RAN.
    #expect(try await c.call("session.list", as: [Session].self).allSatisfy { $0.worktreeId != pr["id"]?.string })
    #expect(!FileManager.default.fileExists(atPath: (pr["path"]?.string ?? "") + "/SETUP_RAN"))
}

@Test func endToEnd() async throws {
    let (d, c, root, repo) = try await world()
    defer { d.stop() }
    #expect(try await c.call("ping").string == "pong")
    // .kelp.yaml's setup waits for the user to trust the file
    let first = try await c.call("worktree.create", .obj(["repoId": .string(repo.id), "branch": "feat/zero"]))
    #expect(first["setupNeedsTrust"]?.bool == true)
    _ = try await trustAsShown(c, first["id"] ?? .null)
    let wt: Worktree = try await c.call(
        "worktree.create", .obj(["repoId": .string(repo.id), "branch": "feat/one"]), as: Worktree.self)
    #expect(FileManager.default.fileExists(atPath: wt.path))
    #expect(!FileManager.default.fileExists(atPath: (first["path"]?.string ?? "") + "/SETUP_RAN"))
    // .kelp.yaml setup script ran in the new worktree
    #expect(try await waitFor { FileManager.default.fileExists(atPath: wt.path + "/SETUP_RAN") })

    // session: output, history on re-attach, hook status, send
    let notes = NoteBox()
    c.onNotification = { m, p in notes.add(m, p) }
    let s: Session = try await c.call(
        "session.create", .obj(["worktreeId": .string(wt.id), "command": "echo ready; cat"]), as: Session.self)
    let attached = try await c.call("session.attach", .obj(["id": .string(s.id)]))
    // Printed before the attach, it's in the history the attach answers with; after it, an event.
    let before = String(decoding: Data(base64Encoded: attached["history"]?.string ?? "") ?? Data(), as: UTF8.self)
    #expect(try await waitFor { (before + notes.output(s.id)).contains("ready") })
    _ = try await c.call("session.send", .obj(["id": .string(s.id), "text": "ping-pong"]))
    #expect(try await waitFor { notes.output(s.id).contains("ping-pong") })

    let c2 = try client(root)   // a "restarted UI"
    let h = try await c2.call("session.attach", .obj(["id": .string(s.id)]))
    let hist = String(decoding: Data(base64Encoded: h["history"]!.string!)!, as: UTF8.self)
    #expect(hist.contains("ready") && hist.contains("ping-pong"))
    #expect(try await c2.call("session.read", .obj(["id": .string(s.id)])).string?.contains("ready") == true)

    _ = try await c2.call("session.hook", .obj(["id": .string(s.id), "event": "waiting"]))
    let list: [Session] = try await c2.call("session.list", as: [Session].self)
    #expect(list.first { $0.id == s.id }?.status == .waiting)
    #expect(list.first { $0.id == s.id }?.unread == true)

    // git flow through RPC: change, hunk list, stage, commit, merge
    try "hello\nworld\n".write(toFile: wt.path + "/a.txt", atomically: true, encoding: .utf8)
    let diff: [FileDiff] = try await c2.call(
        "git.diff", .obj(["id": .string(wt.id), "source": "unstaged"]), as: [FileDiff].self)
    #expect(diff.first?.path == "a.txt")
    _ = try await c2.call("git.stage", .obj(["id": .string(wt.id), "files": .array(["a.txt"])]))
    _ = try await c2.call("git.commit", .obj(["id": .string(wt.id), "message": "world"]))
    let m = try await c2.call("git.merge", .obj(["id": .string(wt.id)]))
    #expect(m["merged"]?.bool == true)
    #expect(try String(contentsOfFile: repo.path + "/a.txt", encoding: .utf8) == "hello\nworld\n")

    _ = try await c2.call("session.kill", .obj(["id": .string(s.id)]))
    #expect(
        try await waitFor {
            try await c2.call("session.list", as: [Session].self).first { $0.id == s.id }?.status == .exited
        })
}

@Test func stageHunkByItsHeader() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let c = w.c, wt = try await workspace(w, "s")
    try "hello\nagain\n".write(toFile: wt.path + "/a.txt", atomically: true, encoding: .utf8)
    let header = try #require(
        try await c.call("git.diff", .obj(["id": .string(wt.id), "source": "unstaged"]), as: [FileDiff].self).first?
            .hunks.first?.header)
    // The header decides, not the index (which another view of the file may have counted differently); a stale one stages nothing.
    await #expect(throws: (any Error).self) {
        try await c.call("git.hunk", .obj(["id": .string(wt.id), "file": "a.txt", "hunk": 0, "header": "@@ -9 +9 @@"]))
    }
    _ = try await c.call(
        "git.hunk", .obj(["id": .string(wt.id), "file": "a.txt", "hunk": 5, "header": .string(header)]))
    #expect(
        try await c.call("git.status", .obj(["id": .string(wt.id)]), as: [FileChange].self).first {
            $0.path == "a.txt"
        }?.staged == true)
}

final class NoteBox: @unchecked Sendable {
    private let l = NSLock()
    private var out: [String: String] = [:]
    func add(_ m: String, _ p: JSONValue) {
        guard m == "event.output", let id = p["session"]?.string, let b = p["data"]?.string,
            let d = Data(base64Encoded: b)
        else { return }
        l.lock()
        out[id, default: ""] += String(decoding: d, as: UTF8.self)
        l.unlock()
    }
    func output(_ id: String) -> String {
        l.lock()
        defer { l.unlock() }
        return out[id] ?? ""
    }
}

@Test func aiFeatures() async throws {
    // A fake agent: asks the trust question, then echoes whatever prompt it gets.
    let script =
        #"printf 'Do you trust the files in this folder? '; read -r a; echo TRUST-OK; while read -r l; do echo "GOT:$l"; done"#
    let (d, c, _) = try daemon(agents: [
        AgentManifest(
            id: "fake", name: "Fake", command: "/bin/zsh", args: ["-c", script],
            autoAnswers: [.init(pattern: "(?i)do you trust", input: "\r")], resumeArgs: [])
    ])
    defer { d.stop() }

    let repoPath = try makeRepo()
    try ".env.secret\nnode_modules\n".write(toFile: repoPath + "/.gitignore", atomically: true, encoding: .utf8)
    try "SECRET=1\n".write(toFile: repoPath + "/.env.secret", atomically: true, encoding: .utf8)
    try ".env.*\n".write(toFile: repoPath + "/.worktreeinclude", atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(atPath: repoPath + "/node_modules/x", withIntermediateDirectories: true)
    try "shared: node_modules\n".write(toFile: repoPath + "/.kelp.yaml", atomically: true, encoding: .utf8)
    try Git.run(["add", "."], cwd: repoPath)
    try Git.run(["commit", "-qm", "cfg"], cwd: repoPath)

    let box = NoteBox()
    c.onNotification = { m, p in box.add(m, p) }
    let repo: Repo = try await c.call("repo.add", .obj(["path": .string(repoPath)]), as: Repo.self)
    // .kelp.yaml links nothing until the user trusts this version of it.
    let first = try await c.call("worktree.create", .obj(["repoId": .string(repo.id), "branch": "first"]))
    #expect(first["setupNeedsTrust"]?.bool == true)
    #expect(
        (try? FileManager.default.destinationOfSymbolicLink(atPath: (first["path"]?.string ?? "") + "/node_modules"))
            == nil)
    _ = try await trustAsShown(c, first["id"] ?? .null)
    let wt: Worktree = try await c.call(
        "worktree.create", .obj(["repoId": .string(repo.id), "branch": "dark-mode", "setup": false]), as: Worktree.self)
    let s: Session = try await c.call(
        "session.create",
        .obj(["worktreeId": .string(wt.id), "agent": "fake", "prompt": "Add a dark mode toggle to settings"]),
        as: Session.self)
    #expect(FileManager.default.fileExists(atPath: wt.path + "/.env.secret"))   // .worktreeinclude
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: wt.path + "/node_modules")) != nil)   // shared
    _ = try await c.call("session.attach", .obj(["id": .string(s.id)]))
    #expect(try await waitFor(15) { box.output(s.id).contains("TRUST-OK") })   // auto-answer
    #expect(try await waitFor(15) { box.output(s.id).contains("GOT:Add a dark mode toggle") })   // launch prompt
    #expect(
        try await waitFor(10) {
            (try await c.call("session.list", as: [Session].self)).first { $0.id == s.id }?.title.isEmpty == false
        })

    _ = try await c.call("session.rename", .obj(["id": .string(s.id), "title": "Mine"]))
    #expect(try await c.call("session.list", as: [Session].self).first { $0.id == s.id }?.title == "Mine")

    let ctx = try await c.call("session.context", .obj(["id": .string(s.id)]))
    #expect(ctx.string?.contains("GOT:") == true)

    let h: Session = try await c.call(
        "session.handoff", .obj(["id": .string(s.id), "agent": "fake"]), as: Session.self)
    _ = try await c.call("session.attach", .obj(["id": .string(h.id)]))
    #expect(try await waitFor(20) { box.output(h.id).contains("GOT:Read ") })
    #expect(h.worktreeId == wt.id && h.title.contains("handoff"))

    let rs: Session = try await c.call("session.restart", .obj(["id": .string(s.id)]), as: Session.self)
    #expect(rs.cwd == s.cwd && rs.argv == s.argv && rs.title == "Mine")
}

@Test func hibernateAndWake() async throws {
    // A resumable fake agent: prints whether it was resumed.
    let w = try await world(agents: [
        AgentManifest(
            id: "sleepy", name: "Sleepy", command: "/bin/zsh", args: ["-c", #"echo "STARTED $*"; sleep 30"#, "x"],
            resumeArgs: ["--resume"])
    ])
    defer { w.d.stop() }
    let c = w.c, wt = try await workspace(w, "h")
    let s: Session = try await c.call(
        "session.create", .obj(["worktreeId": .string(wt.id), "agent": "sleepy"]), as: Session.self)
    try await hibernate(after: 0.03, c)   // ~2 s
    #expect(
        try await waitFor(15) {
            try await c.call("session.list", as: [Session].self).first { $0.id == s.id }?.status == .paused
        })
    // A hook that comes after the pause (the agent was on its way out) doesn't wake it.
    _ = try await c.call("session.hook", .obj(["id": .string(s.id), "event": "done"]))
    #expect(try await c.call("session.list", as: [Session].self).first { $0.id == s.id }?.status == .paused)
    // Opening it again resumes the same session id with the resume flag.
    let box = NoteBox()
    c.onNotification = { m, p in box.add(m, p) }
    try await hibernate(after: 0, c)
    _ = try await c.call("session.attach", .obj(["id": .string(s.id)]))
    #expect(try await waitFor(30) { box.output(s.id).contains("STARTED") && box.output(s.id).contains("--resume") })
    #expect(try await c.call("session.list", as: [Session].self).first { $0.id == s.id }?.status != .paused)
    // Its log goes on from before the pause: both runs are there.
    let log = try String(contentsOf: w.root.appendingPathComponent("history/\(s.id).log"), encoding: .utf8)
    #expect(log.components(separatedBy: "STARTED").count == 3)
}

/// Every project has a main workspace on the repo itself; "+" makes "Workspace N" instantly; the main one can't be deleted.
@Test func workspacesMainAndInstant() async throws {
    let (d, c, _, repo) = try await world()
    defer { d.stop() }
    let list: [Worktree] = try await c.call("worktree.list", .obj(["repoId": .string(repo.id)]), as: [Worktree].self)
    let main = list.first { $0.path == repo.path }
    #expect(main != nil)
    let w: Worktree = try await c.call(
        "worktree.create", .obj(["repoId": .string(repo.id), "setup": false]), as: Worktree.self)
    #expect(w.note == "Workspace 2" && w.branch == "ws-2")
    await #expect(throws: RPCError.self) {
        _ = try await c.call("worktree.remove", .obj(["id": .string(main?.id ?? "")]))
    }
}

/// A workspace in the project folder has no branch or checkout of its own; closing one leaves the files, the last stays.
@Test func workspacesShareTheProjectFolder() async throws {
    let (d, c, _, repo) = try await world()
    defer { d.stop() }
    let workspace: Worktree = try await c.call(
        "workspace.create", .obj(["repoId": .string(repo.id)]), as: Worktree.self)   // before any list
    let first = try #require(
        try await c.call("worktree.list", .obj(["repoId": .string(repo.id)]), as: [Worktree].self).first {
            $0.id != workspace.id
        })
    #expect(first.note == "Workspace 1" && first.path == repo.path)
    #expect(workspace.note == "Workspace 2" && workspace.path == repo.path && workspace.branch == first.branch)
    #expect(!Git.branchExists(repo.path, "ws-2"))
    _ = try await c.call("worktree.remove", .obj(["id": .string(workspace.id)]))
    #expect(FileManager.default.fileExists(atPath: repo.path))
    await #expect(throws: RPCError.self) { _ = try await c.call("worktree.remove", .obj(["id": .string(first.id)])) }
}

/// Summaries start from the agent's own last reply, not the terminal around it.
@Test func removeCleanWorktrees() async throws {
    let (d, c, _, repo) = try await world()
    defer { d.stop() }
    let repoPath = repo.path
    // An agent's leftovers: one where main is, one with a commit of its own, one with a file git doesn't track yet.
    // And one on a detached HEAD with a commit no branch has.
    for n in ["same", "ahead", "untracked"] {
        try Git.run(["worktree", "add", "-q", "-b", "agent-" + n, ".claude/worktrees/" + n], cwd: repoPath)
    }
    try Git.run(["worktree", "add", "-q", "--detach", ".claude/worktrees/detached"], cwd: repoPath)
    let wt = repoPath + "/.claude/worktrees/"
    try Git.run(["commit", "-q", "--allow-empty", "-m", "own"], cwd: wt + "ahead")
    try Git.run(["commit", "-q", "--allow-empty", "-m", "loose"], cwd: wt + "detached")
    try "x".write(toFile: wt + "untracked/new.txt", atomically: true, encoding: .utf8)

    let sizes = try await c.call(RepoWorktreeSizes(id: repo.id))
    #expect(Set(sizes.filter(\.removable).map { ($0.path as NSString).lastPathComponent }) == ["same", "ahead"])
    let res = try await c.call(RepoRemoveWorktrees(id: repo.id, paths: sizes.map(\.path) + [repoPath]))
    #expect(res.removed.count == 2 && res.kept.count == 3)   // the untracked file, the loose commit and the main checkout stay
    #expect(FileManager.default.fileExists(atPath: wt + "detached"))
    #expect(
        FileManager.default.fileExists(atPath: wt + "untracked/new.txt")
            && !FileManager.default.fileExists(atPath: wt + "same"))
    #expect(!Git.branchExists(repoPath, "agent-same") && Git.branchExists(repoPath, "agent-ahead"))   // its commit lives on
}

@Test func lastReplyFromTranscript() throws {
    let f = tmp().appendingPathComponent("t.jsonl")
    let lines = [
        #"{"type":"user","message":{"content":"hi"}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"First answer."}]}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"Fixed the parser tests."}]}}"#,
        #"{"type":"system","subtype":"stop"}"#
    ]
    try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (lines.joined(separator: "\n") + "\n").write(to: f, atomically: true, encoding: .utf8)
    #expect(AgentUsage.lastReply(transcript: f) == "Fixed the parser tests.")
}

/// The context ring reads the last real reply, skips subagents and API errors, and drops to what a compaction left.
@Test func contextUsageFromTranscript() throws {
    let f = tmp().appendingPathComponent("t.jsonl")
    try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
    func write(_ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: f, atomically: true, encoding: .utf8)
    }
    let reply =
        #"{"type":"assistant","message":{"model":"m","usage":{"input_tokens":2,"cache_read_input_tokens":250000,"cache_creation_input_tokens":8,"output_tokens":90}}}"#
    try write([
        reply,
        #"{"type":"assistant","isSidechain":true,"message":{"model":"m","usage":{"input_tokens":5}}}"#,
        #"{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}"#
    ])
    let c = try #require(AgentUsage.contextUsage(transcript: f))
    #expect(c.used == 250_010 && c.peak == 250_010 && c.model == "m")   // the reply's output isn't counted, as in Claude Code
    try write([
        reply,
        #"{"type":"system","subtype":"compact_boundary","compactMetadata":{"preTokens":260000,"postTokens":40000}}"#
    ])
    let after = try #require(AgentUsage.contextUsage(transcript: f))
    #expect(after.used == 40_000 && after.peak == 260_000 && after.model == "m")
}

/// OSC 7501: a hookless agent probes, the daemon answers as the terminal, and its own report sets the status.
@Test func programStatusFromTheAgent() async throws {
    let script =
        #"stty -icanon -echo; printf '\033]7501;?\033\\'; IFS= read -r -t 5 -d '\' reply; "#
        + #"[[ $reply == *states=idle* ]] && printf '\033]7501;state=blocked:kind=permission:msg=QWxsb3cgcm0/\033\\'; sleep 30"#
    let p = try await world(agents: [AgentManifest(id: "osc", name: "OSC", command: "/bin/bash", args: ["-c", script])])
    defer { p.d.stop() }
    let c = p.c, w = try await firstWorkspace(p)
    let s: Session = try await c.call(
        "session.create", .obj(["worktreeId": .string(w.id), "agent": "osc"]), as: Session.self)
    #expect(
        try await waitFor(10) {
            try await c.call("session.list", as: [Session].self).first { $0.id == s.id }?.status == .waiting
        })
    #expect(try await c.call("session.list", as: [Session].self).first { $0.id == s.id }?.summary == "Allow rm?")
}

/// Pi and Droid probe with a device attributes query behind OSC 7501's: with no terminal attached the daemon answers
/// both, the 7501 reply first, else they never report.
@Test func probeWithAttributesIsAnsweredHeadless() async throws {
    let script =
        #"stty -icanon -echo; printf '\033]7501;?\033\\\033[c'; IFS= read -r -t 3 -d '\' first; IFS= read -r -t 3 -d c da; "#
        + #"[[ $first == *states=* && $da == *'[?62;22' ]] && echo BOTH-IN-ORDER || echo NO; sleep 30"#
    let p = try await world(agents: [AgentManifest(id: "osc", name: "OSC", command: "/bin/bash", args: ["-c", script])])
    defer { p.d.stop() }
    let c = p.c, w = try await firstWorkspace(p)
    let s: Session = try await c.call(
        "session.create", .obj(["worktreeId": .string(w.id), "agent": "osc"]), as: Session.self)
    #expect(
        try await waitFor(10) {
            let screen = try await c.call("session.read", .obj(["id": .string(s.id)])).string ?? ""
            return screen.contains("BOTH-IN-ORDER") || screen.contains("NO")
        })
    let screen = try await c.call("session.read", .obj(["id": .string(s.id)])).string ?? ""
    #expect(screen.contains("BOTH-IN-ORDER"), "\(screen)")
}

/// The daemon's own replies (OSC 7501's answer, an auto-answer) wait behind a send: a probe printed between the text and
/// its Enter gets its answer after the Enter, not inside the line being typed.
@Test func aReplyDoesntLandInsideASend() async throws {
    let script =
        #"stty -icanon -echo; IFS= read -rn1 first; printf '\033]7501;?\033\\'; IFS= read -r -t 5 -d '\' rest; "#
        + #"[[ $rest == i$'\n'* ]] && echo IN-ORDER || echo MIXED; sleep 30"#
    let p = try await world(agents: [AgentManifest(id: "osc", name: "OSC", command: "/bin/bash", args: ["-c", script])])
    defer { p.d.stop() }
    let c = p.c, w = try await firstWorkspace(p)
    let s: Session = try await c.call(
        "session.create", .obj(["worktreeId": .string(w.id), "agent": "osc"]), as: Session.self)
    _ = try await c.call("session.send", .obj(["id": .string(s.id), "text": "hi"]))
    #expect(
        try await waitFor(10) {
            let screen = try await c.call("session.read", .obj(["id": .string(s.id)])).string ?? ""
            return screen.contains("IN-ORDER") || screen.contains("MIXED")
        })
    #expect(try await c.call("session.read", .obj(["id": .string(s.id)])).string?.contains("IN-ORDER") == true)
}

/// A notification's "Allow": the daemon walks the agent's menu to the Yes option and confirms it there.
@Test func answerAMenuFromOutside() async throws {
    let script =
        #"stty -icanon -echo; printf 'Do you want to proceed?\n\xe2\x9d\xaf 1. Yes\n  2. Yes, and do not ask again\n  3. No\n'; IFS= read -rsn1 k; [[ -z "$k" ]] && echo ALLOWED; sleep 30"#
    let p = try await world(agents: [
        AgentManifest(id: "menu", name: "Menu", command: "/bin/bash", args: ["-c", script])
    ])
    defer { p.d.stop() }
    let c = p.c, w = try await firstWorkspace(p)
    let s: Session = try await c.call(
        "session.create", .obj(["worktreeId": .string(w.id), "agent": "menu"]), as: Session.self)
    #expect(
        try await waitFor(5) {
            try await c.call("session.read", .obj(["id": .string(s.id)])).string?.contains("3. No") == true
        })
    #expect(try await c.call("session.choose", .obj(["id": .string(s.id), "answer": "allow"])).bool == true)
    #expect(
        try await waitFor(5) {
            try await c.call("session.read", .obj(["id": .string(s.id)])).string?.contains("ALLOWED") == true
        })
}

/// A hand-off brief is the conversation itself: what was asked and answered, not tool output.
@Test func handoffBriefFromTranscript() throws {
    let u = tmp().appendingPathComponent("t.jsonl")
    let lines = [
        #"{"type":"user","message":{"role":"user","content":"Add a login page"}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"I'll add it."},{"type":"tool_use","name":"Write"}]}}"#,
        #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#,
        #"{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done: login.html"}]}}"#
    ]
    try lines.joined(separator: "\n").write(to: u, atomically: true, encoding: .utf8)
    let brief = try #require(AgentUsage.conversation(transcript: u, limit: 10_000))
    #expect(brief == "## You\n\nAdd a login page\n\n## Agent\n\nI'll add it.\n\n## Agent\n\nDone: login.html")
}

/// Codex's rollout and pi's session read the same way: only what was said, not injected context or tool calls.
@Test func handoffBriefFromCodexAndPi() throws {
    let codex = tmp().appendingPathComponent("rollout.jsonl"), pi = tmp().appendingPathComponent("pi.jsonl")
    try [
        #"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"rules"}]}}"#,
        #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>x</environment_context>"}]}}"#,
        ##"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions"}]}}"##,
        #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix the build"}]}}"#,
        #"{"type":"response_item","payload":{"type":"reasoning","summary":[]}}"#,
        #"{"type":"event_msg","payload":{"type":"agent_message","message":"Fixed"}}"#,
        #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Fixed"}]}}"#
    ].joined(separator: "\n").write(to: codex, atomically: true, encoding: .utf8)
    try [
        #"{"type":"session","cwd":"/tmp"}"#,
        #"{"type":"message","message":{"role":"system","content":"prompt"}}"#,
        #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Fix the build"}]}}"#,
        #"{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hm"},{"type":"toolCall","name":"bash"}]}}"#,
        #"{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Fixed"}]}}"#
    ].joined(separator: "\n").write(to: pi, atomically: true, encoding: .utf8)
    for file in [codex, pi] {
        #expect(
            AgentUsage.conversation(transcript: file, limit: 10_000) == "## You\n\nFix the build\n\n## Agent\n\nFixed")
    }
}

/// pi keeps a folder's conversations under its real path with "/" as "-": the newest written since the session began.
@Test func piConversationOfAFolder() throws {
    let root = tmp(), cwd = tmp()
    let real = try #require(Paths.real(cwd.path))
    let dir = root.appendingPathComponent("--" + real.dropFirst().replacing("/", with: "-") + "--")
    try Paths.ensure(dir)
    let old = dir.appendingPathComponent("a.jsonl"), new = dir.appendingPathComponent("b.jsonl")
    try "{}".write(to: old, atomically: true, encoding: .utf8)
    try "{}".write(to: new, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
    #expect(
        PiHistory.newest(cwd: cwd.path, since: Date(timeIntervalSinceNow: -60), root: root)?.lastPathComponent
            == "b.jsonl")
    #expect(PiHistory.newest(cwd: cwd.path, since: Date(timeIntervalSinceNow: 60), root: root) == nil)
}

/// A server a workspace's terminal started shows up as that workspace's port, and only there.
@Test func workspacePorts() async throws {
    let p = try await world()
    defer { p.d.stop() }
    let c = p.c, w = try await firstWorkspace(p)
    let server =
        #"python3 -c "import socket,time;s=socket.socket();s.bind(('127.0.0.1',0));s.listen();print('PORT',s.getsockname()[1],flush=True);time.sleep(30)""#
    let s: Session = try await c.call(
        "session.create", .obj(["worktreeId": .string(w.id), "command": .string(server)]), as: Session.self)
    var port = 0
    #expect(
        try await waitFor(10) {
            let out = try await c.call("session.read", .obj(["id": .string(s.id)])).string ?? ""
            port = out.firstMatch(of: /PORT (\d+)/).flatMap { Int($0.1) } ?? 0
            return port > 0
        })
    #expect(
        try await waitFor(5) {
            (try await c.call("ports.list", .obj(["worktreeId": .string(w.id)])).array ?? []).contains {
                $0["port"]?.int == port
            }
        })
    #expect(try await c.call("ports.list", .obj(["worktreeId": "nope"])).array?.isEmpty == true)
}

/// Clone a repo by its path, refuse a taken name, remove what a failed clone left, and start an empty project.
@Test func cloneAndCreateProjects() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let src = try makeRepo(), parent = tmp().path
    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    #expect(
        RepoClone.folderName("git@github.com:me/app.git") == "app"
            && RepoClone.folderName("https://gitlab.com/me/tool/") == "tool")
    let r = try await c.call("repo.clone", .obj(["url": .string(src), "parent": .string(parent), "id": "a"]))
    let name = (src as NSString).lastPathComponent
    #expect(r["path"]?.string?.hasSuffix("/" + name) == true)
    await #expect(throws: (any Error).self) {
        try await c.call("repo.clone", .obj(["url": .string(src), "parent": .string(parent), "id": "b"]))
    }
    // git's own words, not just its exit code.
    let missing = await #expect(throws: RPCError.self) {
        try await c.call("repo.clone", .obj(["url": .string(src + "-missing"), "parent": .string(parent), "id": "c"]))
    }
    #expect(missing?.message.contains("does not exist") == true, "\(String(describing: missing))")
    #expect(!FileManager.default.fileExists(atPath: parent + "/" + name + "-missing"))
    let named = try await c.call(
        "repo.clone", .obj(["url": .string(src), "parent": .string(parent), "folder": "fork", "id": "d"]))
    #expect(named["path"]?.string?.hasSuffix("/fork") == true)
    // Add Project's New Folder: an empty folder is asked about like any other outside git, then made a repository.
    try FileManager.default.createDirectory(atPath: parent + "/empty", withIntermediateDirectories: false)
    await #expect(throws: RepoAdd.notARepository) {
        try await c.call("repo.add", .obj(["path": .string(parent + "/empty")]))
    }
    let e = try await c.call("repo.add", .obj(["path": .string(parent + "/empty"), "init": true]))
    #expect(e["name"]?.string == "empty" && FileManager.default.fileExists(atPath: parent + "/empty/.git"))
}

/// A busy session's CPU and memory come back as its own, summed over what runs under it.
@Test func sessionUsage() async throws {
    let p = try await world()
    defer { p.d.stop() }
    let c = p.c, w = try await firstWorkspace(p)
    let s: Session = try await c.call(
        "session.create", .obj(["worktreeId": .string(w.id), "command": "yes > /dev/null"]), as: Session.self)
    #expect(
        try await waitFor(10) {
            let all = try await c.call("session.usage", as: [SessionUsage.Usage].self)
            guard let u = all.first(where: { $0.session == s.id }) else { return false }
            return u.cpu > 5 && u.memory > 0
        })
}
