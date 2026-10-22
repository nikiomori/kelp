import Foundation
import Testing
import Core
import GitKit
@testable import Daemon
import Agents
@_exported import TestSupport   // tmp() and the rest, for every file of these tests

/// Every test that starts a daemon goes through `tmp()` (TestSupport), which isolates the whole test process first.
let testRoot = TestIsolation.root

/// `ssh` that runs the command here (the host is this Mac). One for the whole test process, made before anything reads
/// a daemon (its `Remotes` reads KELP_SSH as it starts): two tests making their own could overwrite each other's.
let localSSH: String = {
    let shim = tmp().appendingPathComponent("ssh")
    try? """
    #!/bin/sh
    while [ $# -gt 1 ]; do case "$1" in -o) shift 2;; -T|-tt|--) shift;; *) shift; break;; esac; done
    printf '%s\\n' "$1" >> "$(dirname "$0")/ssh.log"
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
    try Git.run(["add", "."], cwd: d); try Git.run(["commit", "-qm", "init"], cwd: d)
    return d
}

func waitFor(_ timeout: Double = 8, _ cond: () async throws -> Bool) async throws -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if try await cond() { return true }; try await Task.sleep(for: .milliseconds(100)) }
    return false
}

/// Another client of the daemon whose home is `root` (a "restarted UI").
func client(_ root: URL) throws -> RPCClient { try RPCClient(socket: root.appendingPathComponent("kelp.sock").path) }

/// A daemon on a fresh home with `agents` in its agents folder, started, and a client of it.
func daemon(agents: [AgentManifest] = [], lsp: LSPHost = LSPHost()) throws -> (d: Daemon, c: RPCClient, root: URL) {
    let root = tmp(); let d = try Daemon(root: root, store: nil, lsp: lsp)
    if !agents.isEmpty {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("agents"), withIntermediateDirectories: true)
        for a in agents { try JSONEncoder().encode(a).write(to: root.appendingPathComponent("agents/\(a.id).json")) }
    }
    try d.start()
    return (d, try client(root), root)
}

typealias World = (d: Daemon, c: RPCClient, root: URL, repo: Repo)
/// `daemon(agents:)` with one project (`makeRepo`) added.
func world(agents: [AgentManifest] = []) async throws -> World {
    let (d, c, root) = try daemon(agents: agents)
    return (d, c, root, try await c.call("repo.add", .obj(["path": .string(try makeRepo())]), as: Repo.self))
}

/// The project's first workspace: its own folder.
func firstDesk(_ w: World) async throws -> Worktree {
    try #require(try await w.c.call("worktree.list", as: [Worktree].self).first { $0.repoId == w.repo.id })
}

/// Sessions left alone this long pause (0: never).
func hibernate(after minutes: Double, _ c: RPCClient) async throws {
    _ = try await c.call("settings.set", .obj(["key": "sessions.hibernateMinutes", "value": .double(minutes)]))
}

/// A new workspace on `branch`, its setup not run.
func desk(_ w: World, _ branch: String) async throws -> Worktree {
    try await w.c.call("worktree.create", .obj(["repoId": .string(w.repo.id), "branch": .string(branch), "setup": false]), as: Worktree.self)
}

@Test func endToEnd() async throws {
    let (d, c, root, repo) = try await world(); defer { d.stop() }
    #expect(try await c.call("ping").string == "pong")
    // .kelp.yaml's setup waits for the user to trust the file
    let first = try await c.call("worktree.create", .obj(["repoId": .string(repo.id), "branch": "feat/zero"]))
    #expect(first["setupNeedsTrust"]?.bool == true)
    _ = try await trustAsShown(c, first["id"] ?? .null)
    let wt: Worktree = try await c.call("worktree.create", .obj(["repoId": .string(repo.id), "branch": "feat/one"]), as: Worktree.self)
    #expect(FileManager.default.fileExists(atPath: wt.path))
    #expect(!FileManager.default.fileExists(atPath: (first["path"]?.string ?? "") + "/SETUP_RAN"))
    // .kelp.yaml setup script ran in the new worktree
    #expect(try await waitFor { FileManager.default.fileExists(atPath: wt.path + "/SETUP_RAN") })

    // session: output, history on re-attach, hook status, send
    let notes = NoteBox(); c.onNotification = { m, p in notes.add(m, p) }
    let s: Session = try await c.call("session.create", .obj(["worktreeId": .string(wt.id), "command": "echo ready; cat"]), as: Session.self)
    _ = try await c.call("session.attach", .obj(["id": .string(s.id)]))
    #expect(try await waitFor { notes.output(s.id).contains("ready") })
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
    let diff: [FileDiff] = try await c2.call("git.diff", .obj(["id": .string(wt.id), "source": "unstaged"]), as: [FileDiff].self)
    #expect(diff.first?.path == "a.txt")
    _ = try await c2.call("git.stage", .obj(["id": .string(wt.id), "files": .array(["a.txt"])]))
    _ = try await c2.call("git.commit", .obj(["id": .string(wt.id), "message": "world"]))
    let m = try await c2.call("git.merge", .obj(["id": .string(wt.id)]))
    #expect(m["merged"]?.bool == true)
    #expect(try String(contentsOfFile: repo.path + "/a.txt", encoding: .utf8) == "hello\nworld\n")

    _ = try await c2.call("session.kill", .obj(["id": .string(s.id)]))
    #expect(try await waitFor { try await c2.call("session.list", as: [Session].self).first { $0.id == s.id }?.status == .exited })
}

@Test func reviewCommentsReachAgent() async throws {
    let w = try await world(); defer { w.d.stop() }
    let c = w.c, wt = try await desk(w, "r")
    let box = NoteBox(); c.onNotification = { m, p in box.add(m, p) }
    let s: Session = try await c.call("session.create", .obj(["worktreeId": .string(wt.id), "command": "cat"]), as: Session.self)
    _ = try await c.call("session.attach", .obj(["id": .string(s.id)]))
    _ = try await c.call("comment.add", .obj(["id": .string(wt.id), "file": "a.txt", "start": 1, "end": 2, "quote": "hello", "text": "rename this"]))
    let n = try await c.call("comment.send", .obj(["id": .string(wt.id), "session": .string(s.id)]))
    #expect(n.int == 1)
    #expect(try await waitFor { box.output(s.id).contains("rename this") })
    let comments: [DiffComment] = try await c.call("comment.list", .obj(["id": .string(wt.id)]), as: [DiffComment].self)
    #expect(comments.first?.state == .sent)
}

@Test func stageHunkByItsHeader() async throws {
    let w = try await world(); defer { w.d.stop() }
    let c = w.c, wt = try await desk(w, "s")
    try "hello\nagain\n".write(toFile: wt.path + "/a.txt", atomically: true, encoding: .utf8)
    let header = try #require(try await c.call("git.diff", .obj(["id": .string(wt.id), "source": "unstaged"]), as: [FileDiff].self).first?.hunks.first?.header)
    // The header decides, not the index (which another view of the file may have counted differently); a stale one stages nothing.
    await #expect(throws: (any Error).self) { try await c.call("git.hunk", .obj(["id": .string(wt.id), "file": "a.txt", "hunk": 0, "header": "@@ -9 +9 @@"])) }
    _ = try await c.call("git.hunk", .obj(["id": .string(wt.id), "file": "a.txt", "hunk": 5, "header": .string(header)]))
    #expect(try await c.call("git.status", .obj(["id": .string(wt.id)]), as: [FileChange].self).first { $0.path == "a.txt" }?.staged == true)
}

@Test func discardHunkOnlyWhatWasShown() async throws {
    let w = try await world(); defer { w.d.stop() }
    let c = w.c, wt = try await desk(w, "h")
    try "hello\nagain\n".write(toFile: wt.path + "/a.txt", atomically: true, encoding: .utf8)
    let diff: [FileDiff] = try await c.call("git.diff", .obj(["id": .string(wt.id), "source": "unstaged"]), as: [FileDiff].self)
    let header = try #require(diff.first?.hunks.first?.header)
    // A header that isn't the file's now (it changed since it was shown): nothing goes.
    await #expect(throws: (any Error).self) { try await c.call(GitDiscardHunk(id: wt.id, file: "a.txt", hunk: 0, header: "@@ -9 +9 @@")) }
    #expect(try String(contentsOfFile: wt.path + "/a.txt", encoding: .utf8) == "hello\nagain\n")
    _ = try await c.call(GitDiscardHunk(id: wt.id, file: "a.txt", hunk: 0, header: header))
    #expect(try String(contentsOfFile: wt.path + "/a.txt", encoding: .utf8) == "hello\n")
}

final class NoteBox: @unchecked Sendable {
    private let l = NSLock(); private var out: [String: String] = [:]
    func add(_ m: String, _ p: JSONValue) {
        guard m == "event.output", let id = p["session"]?.string, let b = p["data"]?.string, let d = Data(base64Encoded: b) else { return }
        l.lock(); out[id, default: ""] += String(decoding: d, as: UTF8.self); l.unlock()
    }
    func output(_ id: String) -> String { l.lock(); defer { l.unlock() }; return out[id] ?? "" }
}

@Test func aiFeatures() async throws {
    // A fake agent: asks the trust question, then echoes whatever prompt it gets.
    let script = #"printf 'Do you trust the files in this folder? '; read -r a; echo TRUST-OK; while read -r l; do echo "GOT:$l"; done"#
    let (d, c, _) = try daemon(agents: [AgentManifest(id: "fake", name: "Fake", command: "/bin/zsh", args: ["-c", script],
        autoAnswers: [.init(pattern: "(?i)do you trust", input: "\r")], resumeArgs: [])]); defer { d.stop() }

    let repoPath = try makeRepo()
    try ".env.secret\nnode_modules\n".write(toFile: repoPath + "/.gitignore", atomically: true, encoding: .utf8)
    try "SECRET=1\n".write(toFile: repoPath + "/.env.secret", atomically: true, encoding: .utf8)
    try ".env.*\n".write(toFile: repoPath + "/.worktreeinclude", atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(atPath: repoPath + "/node_modules/x", withIntermediateDirectories: true)
    try "shared: node_modules\n".write(toFile: repoPath + "/.kelp.yaml", atomically: true, encoding: .utf8)
    try Git.run(["add", "."], cwd: repoPath); try Git.run(["commit", "-qm", "cfg"], cwd: repoPath)

    let box = NoteBox(); c.onNotification = { m, p in box.add(m, p) }
    let repo: Repo = try await c.call("repo.add", .obj(["path": .string(repoPath)]), as: Repo.self)
    // .kelp.yaml links nothing until the user trusts this version of it.
    let first = try await c.call("worktree.create", .obj(["repoId": .string(repo.id), "branch": "first"]))
    #expect(first["setupNeedsTrust"]?.bool == true)
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: (first["path"]?.string ?? "") + "/node_modules")) == nil)
    _ = try await trustAsShown(c, first["id"] ?? .null)
    let wt: Worktree = try await c.call("worktree.create", .obj(["repoId": .string(repo.id), "branch": "dark-mode", "setup": false]), as: Worktree.self)
    let s: Session = try await c.call("session.create", .obj(["worktreeId": .string(wt.id), "agent": "fake", "prompt": "Add a dark mode toggle to settings"]),
                                      as: Session.self)
    #expect(FileManager.default.fileExists(atPath: wt.path + "/.env.secret"))              // .worktreeinclude
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: wt.path + "/node_modules")) != nil)   // shared
    _ = try await c.call("session.attach", .obj(["id": .string(s.id)]))
    #expect(try await waitFor(15) { box.output(s.id).contains("TRUST-OK") })                // auto-answer
    #expect(try await waitFor(15) { box.output(s.id).contains("GOT:Add a dark mode toggle") })   // launch prompt
    #expect(try await waitFor(10) { (try await c.call("session.list", as: [Session].self)).first { $0.id == s.id }?.title.isEmpty == false })

    _ = try await c.call("session.rename", .obj(["id": .string(s.id), "title": "Mine"]))
    #expect(try await c.call("session.list", as: [Session].self).first { $0.id == s.id }?.title == "Mine")

    let ctx = try await c.call("session.context", .obj(["id": .string(s.id)]))
    #expect(ctx.string?.contains("GOT:") == true)

    let h: Session = try await c.call("session.handoff", .obj(["id": .string(s.id), "agent": "fake"]), as: Session.self)
    _ = try await c.call("session.attach", .obj(["id": .string(h.id)]))
    #expect(try await waitFor(20) { box.output(h.id).contains("GOT:Read ") })
    #expect(h.worktreeId == wt.id && h.title.contains("handoff"))

    let rs: Session = try await c.call("session.restart", .obj(["id": .string(s.id)]), as: Session.self)
    #expect(rs.cwd == s.cwd && rs.argv == s.argv && rs.title == "Mine")
}

@Test func hibernateAndWake() async throws {
    // A resumable fake agent: prints whether it was resumed.
    let w = try await world(agents: [AgentManifest(id: "sleepy", name: "Sleepy", command: "/bin/zsh", args: ["-c", #"echo "STARTED $*"; sleep 30"#, "x"],
                                                   resumeArgs: ["--resume"])]); defer { w.d.stop() }
    let c = w.c, wt = try await desk(w, "h")
    let s: Session = try await c.call("session.create", .obj(["worktreeId": .string(wt.id), "agent": "sleepy"]), as: Session.self)
    try await hibernate(after: 0.03, c)   // ~2 s
    #expect(try await waitFor(15) { try await c.call("session.list", as: [Session].self).first { $0.id == s.id }?.status == .hibernated })
    // A hook that comes after the pause (the agent was on its way out) doesn't wake it.
    _ = try await c.call("session.hook", .obj(["id": .string(s.id), "event": "done"]))
    #expect(try await c.call("session.list", as: [Session].self).first { $0.id == s.id }?.status == .hibernated)
    // Opening it again resumes the same session id with the resume flag.
    let box = NoteBox(); c.onNotification = { m, p in box.add(m, p) }
    try await hibernate(after: 0, c)
    _ = try await c.call("session.attach", .obj(["id": .string(s.id)]))
    #expect(try await waitFor(10) { box.output(s.id).contains("STARTED") && box.output(s.id).contains("--resume") })
    #expect(try await c.call("session.list", as: [Session].self).first { $0.id == s.id }?.status != .hibernated)
    // Its log goes on from before the pause: both runs are there.
    let log = try String(contentsOf: w.root.appendingPathComponent("history/\(s.id).log"), encoding: .utf8)
    #expect(log.components(separatedBy: "STARTED").count == 3)
}

/// Every project has a main workspace on the repo itself; "+" makes "Workspace N" instantly; the main one can't be deleted.
@Test func workspacesMainAndInstant() async throws {
    let (d, c, _, repo) = try await world(); defer { d.stop() }
    let list: [Worktree] = try await c.call("worktree.list", .obj(["repoId": .string(repo.id)]), as: [Worktree].self)
    let main = list.first { $0.path == repo.path }
    #expect(main != nil)
    let w: Worktree = try await c.call("worktree.create", .obj(["repoId": .string(repo.id), "setup": false]), as: Worktree.self)
    #expect(w.note == "Workspace 2" && w.branch == "ws-2")
    await #expect(throws: RPCError.self) { _ = try await c.call("worktree.remove", .obj(["id": .string(main?.id ?? "")])) }
}

/// A workspace is a desk in the project folder: no branch, no checkout; closing one leaves the files, the last stays.
@Test func desksShareTheProjectFolder() async throws {
    let (d, c, _, repo) = try await world(); defer { d.stop() }
    let desk: Worktree = try await c.call("workspace.create", .obj(["repoId": .string(repo.id)]), as: Worktree.self)   // before any list
    let first = try #require(try await c.call("worktree.list", .obj(["repoId": .string(repo.id)]), as: [Worktree].self).first { $0.id != desk.id })
    #expect(first.note == "Workspace 1" && first.path == repo.path)
    #expect(desk.note == "Workspace 2" && desk.path == repo.path && desk.branch == first.branch)
    #expect(!Git.branchExists(repo.path, "ws-2"))
    _ = try await c.call("worktree.remove", .obj(["id": .string(desk.id)]))
    #expect(FileManager.default.fileExists(atPath: repo.path))
    await #expect(throws: RPCError.self) { _ = try await c.call("worktree.remove", .obj(["id": .string(first.id)])) }
}

/// Summaries start from the agent's own last reply, not the terminal around it.
@Test func removeCleanWorktrees() async throws {
    let (d, c, _, repo) = try await world(); defer { d.stop() }
    let repoPath = repo.path
    // An agent's leftovers: one where main is, one with a commit of its own, one with a file git doesn't track yet.
    for n in ["same", "ahead", "untracked"] { try Git.run(["worktree", "add", "-q", "-b", "agent-" + n, ".claude/worktrees/" + n], cwd: repoPath) }
    let wt = repoPath + "/.claude/worktrees/"
    try Git.run(["commit", "-q", "--allow-empty", "-m", "own"], cwd: wt + "ahead")
    try "x".write(toFile: wt + "untracked/new.txt", atomically: true, encoding: .utf8)

    let sizes = try await c.call(RepoWorktreeSizes(id: repo.id))
    #expect(Set(sizes.filter(\.removable).map { ($0.path as NSString).lastPathComponent }) == ["same", "ahead"])
    let res = try await c.call(RepoRemoveWorktrees(id: repo.id, paths: sizes.map(\.path) + [repoPath]))
    #expect(res.removed.count == 2 && res.kept.count == 2)   // the untracked file and the main checkout stay
    #expect(FileManager.default.fileExists(atPath: wt + "untracked/new.txt") && !FileManager.default.fileExists(atPath: wt + "same"))
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
    func write(_ lines: [String]) throws { try (lines.joined(separator: "\n") + "\n").write(to: f, atomically: true, encoding: .utf8) }
    let reply = #"{"type":"assistant","message":{"model":"m","usage":{"input_tokens":2,"cache_read_input_tokens":250000,"cache_creation_input_tokens":8,"output_tokens":90}}}"#
    try write([reply,
               #"{"type":"assistant","isSidechain":true,"message":{"model":"m","usage":{"input_tokens":5}}}"#,
               #"{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}"#])
    let c = try #require(AgentUsage.contextUsage(transcript: f))
    #expect(c.used == 250_100 && c.peak == 250_100 && c.model == "m")
    try write([reply, #"{"type":"system","subtype":"compact_boundary","compactMetadata":{"preTokens":260000,"postTokens":40000}}"#])
    let after = try #require(AgentUsage.contextUsage(transcript: f))
    #expect(after.used == 40_000 && after.peak == 260_000 && after.model == "m")
}

/// OSC 7501: a hookless agent probes, the daemon answers as the terminal, and its own report sets the status.
@Test func programStatusFromTheAgent() async throws {
    let script = #"stty -icanon -echo; printf '\033]7501;?\033\\'; IFS= read -r -t 5 -d '\' reply; "#
        + #"[[ $reply == *states=idle* ]] && printf '\033]7501;state=blocked:kind=permission:msg=QWxsb3cgcm0/\033\\'; sleep 30"#
    let p = try await world(agents: [AgentManifest(id: "osc", name: "OSC", command: "/bin/bash", args: ["-c", script])]); defer { p.d.stop() }
    let c = p.c, w = try await firstDesk(p)
    let s: Session = try await c.call("session.create", .obj(["worktreeId": .string(w.id), "agent": "osc"]), as: Session.self)
    #expect(try await waitFor(10) { try await c.call("session.list", as: [Session].self).first { $0.id == s.id }?.status == .waiting })
    #expect(try await c.call("session.list", as: [Session].self).first { $0.id == s.id }?.summary == "Allow rm?")
}

/// A notification's "Allow": the daemon walks the agent's menu to the Yes option and confirms it there.
@Test func answerAMenuFromOutside() async throws {
    let script = #"stty -icanon -echo; printf 'Do you want to proceed?\n\xe2\x9d\xaf 1. Yes\n  2. Yes, and do not ask again\n  3. No\n'; IFS= read -rsn1 k; [[ -z "$k" ]] && echo ALLOWED; sleep 30"#
    let p = try await world(agents: [AgentManifest(id: "menu", name: "Menu", command: "/bin/bash", args: ["-c", script])]); defer { p.d.stop() }
    let c = p.c, w = try await firstDesk(p)
    let s: Session = try await c.call("session.create", .obj(["worktreeId": .string(w.id), "agent": "menu"]), as: Session.self)
    #expect(try await waitFor(5) { try await c.call("session.read", .obj(["id": .string(s.id)])).string?.contains("3. No") == true })
    #expect(try await c.call("session.choose", .obj(["id": .string(s.id), "answer": "allow"])).bool == true)
    #expect(try await waitFor(5) { try await c.call("session.read", .obj(["id": .string(s.id)])).string?.contains("ALLOWED") == true })
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

/// A server a workspace's terminal started shows up as that workspace's port, and only there.
@Test func workspacePorts() async throws {
    let p = try await world(); defer { p.d.stop() }
    let c = p.c, w = try await firstDesk(p)
    let server = #"python3 -c "import socket,time;s=socket.socket();s.bind(('127.0.0.1',0));s.listen();print('PORT',s.getsockname()[1],flush=True);time.sleep(30)""#
    let s: Session = try await c.call("session.create", .obj(["worktreeId": .string(w.id), "command": .string(server)]), as: Session.self)
    var port = 0
    #expect(try await waitFor(10) {
        let out = try await c.call("session.read", .obj(["id": .string(s.id)])).string ?? ""
        port = out.firstMatch(of: /PORT (\d+)/).flatMap { Int($0.1) } ?? 0
        return port > 0
    })
    #expect(try await waitFor(5) { (try await c.call("ports.list", .obj(["worktreeId": .string(w.id)])).array ?? []).contains { $0["port"]?.int == port } })
    #expect(try await c.call("ports.list", .obj(["worktreeId": "nope"])).array?.isEmpty == true)
}

/// Clone a repo by its path, refuse a taken name, remove what a failed clone left, and start an empty project.
@Test func cloneAndCreateProjects() async throws {
    let (d, c, _) = try daemon(); defer { d.stop() }
    let src = try makeRepo(), parent = tmp().path
    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    #expect(RepoClone.folderName("git@github.com:me/app.git") == "app" && RepoClone.folderName("https://gitlab.com/me/tool/") == "tool")
    let r = try await c.call("repo.clone", .obj(["url": .string(src), "parent": .string(parent), "id": "a"]))
    let name = (src as NSString).lastPathComponent
    #expect(r["path"]?.string?.hasSuffix("/" + name) == true)
    await #expect(throws: (any Error).self) { try await c.call("repo.clone", .obj(["url": .string(src), "parent": .string(parent), "id": "b"])) }
    await #expect(throws: (any Error).self) { try await c.call("repo.clone", .obj(["url": .string(src + "-missing"), "parent": .string(parent), "id": "c"])) }
    #expect(!FileManager.default.fileExists(atPath: parent + "/" + name + "-missing"))
    let named = try await c.call("repo.clone", .obj(["url": .string(src), "parent": .string(parent), "folder": "fork", "id": "d"]))
    #expect(named["path"]?.string?.hasSuffix("/fork") == true)
    // Add Project's New Folder: an empty folder is asked about like any other outside git, then made a repository.
    try FileManager.default.createDirectory(atPath: parent + "/empty", withIntermediateDirectories: false)
    await #expect(throws: RepoAdd.notARepository) { try await c.call("repo.add", .obj(["path": .string(parent + "/empty")])) }
    let e = try await c.call("repo.add", .obj(["path": .string(parent + "/empty"), "init": true]))
    #expect(e["name"]?.string == "empty" && FileManager.default.fileExists(atPath: parent + "/empty/.git"))
}

/// A busy session's CPU and memory come back as its own, summed over what runs under it.
@Test func sessionUsage() async throws {
    let p = try await world(); defer { p.d.stop() }
    let c = p.c, w = try await firstDesk(p)
    let s: Session = try await c.call("session.create", .obj(["worktreeId": .string(w.id), "command": "yes > /dev/null"]), as: Session.self)
    #expect(try await waitFor(10) {
        let all = try await c.call("session.usage", as: [SessionUsage.Usage].self)
        guard let u = all.first(where: { $0.session == s.id }) else { return false }
        return u.cpu > 5 && u.memory > 0
    })
}

/// The Run menu's commands come from .kelp.yaml and run only after Trust; editing the file asks again.
@Test func projectScriptsNeedTrust() async throws {
    let (d, c, _) = try daemon(); defer { d.stop() }
    let path = try makeRepo()
    try "test: touch TESTED\nscript.hello: echo hi\n".write(toFile: path + "/.kelp.yaml", atomically: true, encoding: .utf8)
    let repo: Repo = try await c.call("repo.add", .obj(["path": .string(path)]), as: Repo.self)
    let w = try #require(try await c.call("worktree.list", as: [Worktree].self).first { $0.repoId == repo.id })
    let id = JSONValue.obj(["worktreeId": .string(w.id)])
    let list = try await c.call("scripts.list", id)
    #expect(list["trusted"]?.bool == false && list["scripts"]?.array?.compactMap { $0["name"]?.string } == ["test", "hello"])
    await #expect(throws: (any Error).self) { try await c.call("scripts.run", .obj(["worktreeId": .string(w.id), "name": "test"])) }
    _ = try await trustAsShown(c, id["worktreeId"] ?? .null)
    _ = try await c.call("scripts.run", .obj(["worktreeId": .string(w.id), "name": "test"]))
    #expect(try await waitFor { FileManager.default.fileExists(atPath: w.path + "/TESTED") })
    try "test: false\n".write(toFile: path + "/.kelp.yaml", atomically: true, encoding: .utf8)
    #expect(try await c.call("scripts.list", id)["trusted"]?.bool == false)
}

@Test func namingFromPrompt() {
    #expect(Naming.slug("Add a dark-mode toggle to the Settings screen!") == "add-dark-mode-toggle-settings")
    #expect(Naming.title("short") == "Short")
    #expect(Naming.title("посмотри ресерч http://localhost:8765/p и предложи как улучшить подсказки") == "Посмотри ресерч и предложи как…")
}

/// A project on another machine: git, the file list, a file and a session all happen "there" (an ssh stand-in that
/// runs the command locally), while Kelp keeps only a placeholder folder.
@Test func remoteProjectOverSSH() async throws {
    _ = localSSH
    let (d, c, root) = try daemon(); defer { d.stop() }
    #expect(d.remotes.ssh == localSSH)
    let there = try makeRepo()
    try "changed\n".write(toFile: there + "/a.txt", atomically: true, encoding: .utf8)
    // The folder browser: the repository is listed and marked; a missing folder says so.
    let listed = try await c.call(RemoteListFolders(host: "box", path: (there as NSString).deletingLastPathComponent))
    #expect(listed.folders.contains(.init(name: (there as NSString).lastPathComponent, git: true)) && !listed.repo)
    #expect(try await c.call(RemoteListFolders(host: "box", path: there)).repo)
    await #expect(throws: (any Error).self) { try await c.call(RemoteListFolders(host: "box", path: "/nope/nothing")) }
    // A folder that isn't a repository opens only with init, which makes it one.
    let loose = tmp().path
    try FileManager.default.createDirectory(atPath: loose, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: loose + "/a.txt", contents: Data())
    await #expect(throws: (any Error).self) { try await c.call("repo.addRemote", .obj(["host": "box", "path": .string(loose)])) }
    _ = try await c.call("repo.addRemote", .obj(["host": "box", "path": .string(loose), "init": true]))
    #expect(FileManager.default.fileExists(atPath: loose + "/.git"))
    let repo: Repo = try await c.call("repo.addRemote", .obj(["host": "box", "path": .string(there)]), as: Repo.self)
    #expect(repo.path.hasPrefix(root.path + "/remote/box/") && !FileManager.default.fileExists(atPath: repo.path + "/a.txt"))
    let w = try #require(try await c.call("worktree.list", as: [Worktree].self).first { $0.repoId == repo.id })
    let status = try await c.call("git.status", .obj(["id": .string(w.id)]), as: [FileChange].self)
    #expect(status.map(\.path) == ["a.txt"])
    // An untracked file there shows with its text (read on the host, not from the marker folder here).
    try "brand new\n".write(toFile: there + "/new.txt", atomically: true, encoding: .utf8)
    let diffs = try await c.call("git.diff", .obj(["id": .string(w.id), "source": "unstaged"]), as: [FileDiff].self)
    #expect(diffs.first { $0.path == "new.txt" }?.hunks.first?.lines.map(\.text) == ["brand new"])
    try FileManager.default.removeItem(atPath: there + "/new.txt")
    // A path that climbs out of the project's folder isn't read on the host.
    try "outside\n".write(toFile: (there as NSString).deletingLastPathComponent + "/outside.txt", atomically: true, encoding: .utf8)
    await #expect(throws: (any Error).self) { _ = try await c.call("files.readRemote", .obj(["path": .string(repo.path + "/../outside.txt")])) }
    // gh / glab would run in the local marker folder (and its git walk up to ~): refused, said plainly.
    do { _ = try await c.call("github.prs", .obj(["worktreeId": .string(w.id)])); Issue.record("ran gh for a remote project") }
    catch { #expect("\(error)".contains("remote projects")) }
    #expect(try await c.call("github.branchPR", .obj(["worktreeId": .string(w.id)])) == .null)
    #expect(try await c.call("files.list", .obj(["id": .string(w.id)]), as: [String].self).contains("a.txt"))
    #expect(try await c.call("files.readRemote", .obj(["path": .string(repo.path + "/a.txt")])).string == "changed\n")
    // Saving writes it there; an edit there since it was read comes back instead, and nothing is written over it.
    let save = { (text: String, base: String) in try await c.call("files.writeRemote", .obj(["path": .string(repo.path + "/a.txt"), "text": .string(text), "base": .string(base)])) }
    #expect(try await save("mine\n", "changed\n") == .null)
    #expect(try String(contentsOfFile: there + "/a.txt", encoding: .utf8) == "mine\n")
    #expect(try await save("again\n", "changed\n") == .obj(["changed": "mine\n"]))
    #expect(try String(contentsOfFile: there + "/a.txt", encoding: .utf8) == "mine\n")
    #expect(try FileManager.default.contentsOfDirectory(atPath: there).allSatisfy { !$0.contains(".kelp-") })
    try "changed\n".write(toFile: there + "/a.txt", atomically: true, encoding: .utf8)
    // Adding it again is the same project; a folder that isn't there says so.
    #expect(try await c.call("repo.addRemote", .obj(["host": "box", "path": .string(there)]), as: Repo.self).id == repo.id)
    await #expect(throws: (any Error).self) { try await c.call("repo.addRemote", .obj(["host": "box", "path": "/nope/nothing"])) }

    let s: Session = try await c.call("session.create", .obj(["worktreeId": .string(w.id), "command": "pwd -P"]), as: Session.self)
    let real = URL(fileURLWithPath: there).resolvingSymlinksInPath().path
    #expect(try await waitFor(10) { (try await c.call("session.read", .obj(["id": .string(s.id)])).string ?? "").contains(real) })
    // A command line runs in sh on the host, not in this Mac's zsh; cwd (the project's folder) picks the host for another workspace's tab.
    let ssh = try d.sessions.launchArgv(["/bin/zsh", "-lc", "claude update"], cwd: repo.path, manifest: .custom("claude update"))
    #expect(ssh.last?.hasSuffix(RemoteHost.quote("'sh' '-c' 'claude update'")) == true)
    let other: Session = try await c.call("session.create", .obj(["cwd": .string(repo.path), "command": "pwd -P"]), as: Session.self)
    #expect(try await waitFor(10) { (try await c.call("session.read", .obj(["id": .string(other.id)])).string ?? "").contains(real) })
}

/// A finished turn moves the agent's plan read up to half a minute away; it never puts a sooner one off.
@Test func turnEndBringsPlanReadForward() throws {
    let d = try Daemon(root: tmp())
    let every = try #require(AgentUsage.planProbes.first { $0.agent == "claude" }).every
    d.agentUsage.plans.withLock { $0["claude"] = .init(at: Date()) }
    d.agentUsage.planUsed("claude")
    let due = try #require(d.agentUsage.plans.withLock { $0 }["claude"]?.at).addingTimeInterval(every).timeIntervalSinceNow
    #expect(due > 25 && due <= 30)
    d.agentUsage.plans.withLock { $0["claude"]?.at = .distantPast }
    d.agentUsage.planUsed("claude")
    #expect(d.agentUsage.plans.withLock { $0 }["claude"]?.at == .distantPast)
}

/// Twice as many stuck git / gh calls as there are cores still leave the daemon answering (they don't hold the cooperative pool).
@Test func blockingCallsLeaveTheDaemonAnswering() async throws {
    let d = try Daemon(root: tmp())
    let n = ProcessInfo.processInfo.activeProcessorCount * 2
    let entered = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0), answered = DispatchSemaphore(value: 0)
    let stuck = (0..<n).map { _ in Task { try await d.offload { entered.signal(); gate.wait() } } }
    let started = signals(entered, n, by: .now() + 20)   // generous: this proves the daemon answers, not how fast, and a loaded machine starts threads slowly
    let ping = Task { let r = try await d.handle("ping", .null, conn: 0); answered.signal(); return r }
    let answeredInTime = signals(answered, 1, by: .now() + 20) == 1   // a daemon whose pool is held would never answer, so this still fails when it should
    for _ in 0..<n { gate.signal() }
    for t in stuck { try await t.value }
    #expect(started == n && answeredInTime)
    #expect(try await ping.value.string == "pong")
}

/// History and usage answer from the agents' folders (empty, then one conversation), now off the cooperative pool.
@Test func historyAndUsageFromAgentFolders() async throws {
    let d = try Daemon(root: tmp()), home = tmp()
    d.agentUsage.agentHomes.withLock { $0 = (home.appendingPathComponent("projects"), home.appendingPathComponent("sessions")) }
    #expect(try await d.handle("history.list", .null, conn: 0) == .array([]))
    let dir = home.appendingPathComponent("projects/-work-app"), now = ISO8601DateFormatter().string(from: Date())
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try [#"{"type":"user","sessionId":"s1","cwd":"/work/app","timestamp":"\#(now)","message":{"role":"user","content":"Fix the parser"}}"#,
         #"{"type":"assistant","cwd":"/work/app","timestamp":"\#(now)","message":{"model":"m","usage":{"input_tokens":3,"output_tokens":5}}}"#]
        .joined(separator: "\n").appending("\n").write(to: dir.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
    let list = try await d.handle("history.list", .obj(["cwd": "/work/app"]), conn: 0)
    #expect(list.array?.map { $0["title"]?.string } == ["Fix the parser"])
    let report = try await d.handle("usage.report", .obj(["days": 1]), conn: 0)
    #expect(report["models"]?.array?.first?["tokens"]?.int == 8)
    await #expect(throws: RPCError.invalidParams("session required")) { try await d.handle("history.resume", .null, conn: 0) }
}

/// A typed call and the same request written by hand (the CLI, an older app) get the same answer.
@Test func typedAndUntypedCallsAgree() async throws {
    let (d, c, _) = try daemon(); defer { d.stop() }
    _ = try await c.call(StateSet(key: "sidebar.order", value: .array(["a"])))
    #expect(try await c.call(StateGet(key: "sidebar.order")) == .array(["a"]))
    #expect(try await c.call("state.get", .obj(["key": "sidebar.order"])) == .array(["a"]))
    _ = try await c.call("state.set", .obj(["key": "layout/w1", "value": 1]))
    #expect(try await c.call(StateGet(prefix: "")) == .obj(["sidebar.order": .array(["a"]), "layout/w1": 1]))
    _ = try await c.call(StateSet(key: "sidebar.order", value: nil))
    #expect(try await c.call("state.get", .obj(["prefix": ""])) == .obj(["layout/w1": 1]))

    let info = try await c.call(DaemonInfo())
    #expect(info.pid == Int(getpid()) && info.liveSessions == 0 && info.binaryMTime == Daemon.binaryMTime)
    #expect(try await c.call("daemon.info") == .from(info))
    #expect(try await c.call(SessionContextWindow(id: "nope")) == nil)
    await #expect(throws: RPCError.invalidParams("missing title")) { try await c.call("session.rename", .obj(["id": "x"])) }
}

/// How many of `n` signals came by the deadline. Blocks this thread on purpose: with a broken offload the cooperative
/// pool is full, and a test that awaited would hang instead of failing.
private func signals(_ s: DispatchSemaphore, _ n: Int, by deadline: DispatchTime) -> Int {
    (0..<n).filter { _ in s.wait(timeout: deadline) == .success }.count
}

@Test func agentTopicNamesSessionAndWorkspace() async throws {
    // Like Claude Code: its own name in the title first, then the conversation's topic.
    let (d, c, _, repo) = try await world(agents: [AgentManifest(id: "topical", name: "Topical", command: "/bin/zsh",
        args: ["-c", #"printf '\e]0;✳ Topical\a'; sleep 1; printf '\e]0;✳ Ревью и оценка приложения\a'; sleep 30"#])]); defer { d.stop() }
    let ws = try await c.call("workspace.create", .obj(["repoId": .string(repo.id)]))
    let wid = try #require(ws["id"]?.string)
    let s: Session = try await c.call("session.create", .obj(["worktreeId": .string(wid), "agent": "topical",
                                                              "prompt": "сделай ревью приложения и дай ему оценку по десятибалльной шкале"]), as: Session.self)
    #expect(try await waitFor(10) { try await c.call("session.list", as: [Session].self).first { $0.id == s.id }?.title == "Ревью и оценка приложения" })
    #expect(try await waitFor(5) { try await c.call("worktree.list", as: [Worktree].self).first { $0.id == wid }?.note == "Ревью и оценка приложения" })
}
