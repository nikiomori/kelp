import Foundation
import Testing
import Core
import GitKit
import Agents
@testable import Daemon

/// A daemon with one repo and one desk (workspace) cut from it, set up the way the app does.
private struct Rig {
    let d: Daemon, c: RPCClient, repo: Repo, wt: Worktree
    func call(_ m: String, _ p: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await c.call(m, .object(p.merging(["id": .string(wt.id)]) { a, _ in a }))
    }
}
private func rig() async throws -> Rig {
    let w = try await world()
    return Rig(d: w.d, c: w.c, repo: w.repo, wt: try await desk(w, "feat/x"))
}
private func write(_ r: Rig, _ name: String, _ text: String) throws { try text.write(toFile: r.wt.path + "/" + name, atomically: true, encoding: .utf8) }

@Test func repoListHasTheAddedRepo() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let repos = try await r.c.call("repo.list", as: [Repo].self)
    #expect(repos.contains { $0.id == r.repo.id })
}

@Test func branchesSwitchAndLogFollowTheDesk() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let b = try await r.c.call("git.branches", .obj(["id": .string(r.wt.id)]), as: BranchInfo.self)
    #expect(b.current == "feat/x" && b.local.contains("main"))
    _ = try await r.call("git.switch", ["branch": "feat/y", "create": true])
    #expect(try await r.c.call("git.branches", .obj(["id": .string(r.wt.id)]), as: BranchInfo.self).current == "feat/y")
    let log = try await r.call("git.log", ["all": true]).array ?? []
    #expect(log.first?["subject"]?.string == "init")
}

@Test func graphListsCommitsAndSaysWhenThereAreMore() async throws {
    let r = try await rig(); defer { r.d.stop() }
    try write(r, "b.txt", "b\n")
    _ = try await r.call("git.stage", ["files": .array([.string("b.txt")])])
    _ = try await r.call("git.commit", ["message": "second"])
    let g = try await r.call("git.graph", ["limit": 1])
    #expect(g["commits"]?.array?.count == 1 && g["more"]?.bool == true)
    let all = try await r.call("git.graph", ["limit": 10])
    #expect(all["more"]?.bool == false)
    let hash = try #require(all["commits"]?.array?.first?["hash"]?.string)
    let files = try await r.call("git.commitFiles", ["commit": .string(hash)]).array ?? []
    #expect(files.compactMap { $0["path"]?.string } == ["b.txt"])
    let details = try await r.call("git.commitDetails", ["commit": .string(hash)])
    #expect(details["files"]?.int == 1 && details["added"]?.int == 1 && details["body"]?.string == "")
    // No forge behind the project and no GitHub noreply address: no picture, and nothing asked over the network.
    #expect(try await r.call("git.authorAvatar", ["email": "ada@example.com"]) == .null)
}

@Test func discardBringsBackTheFileAndStashHidesAndRestoresChanges() async throws {
    let r = try await rig(); defer { r.d.stop() }
    #expect(try await r.call("worktree.dirty").bool == false)
    try write(r, "a.txt", "changed\n")
    #expect(try await r.call("worktree.dirty").bool == true)
    _ = try await r.call("git.stash")
    #expect(try await r.call("worktree.dirty").bool == false)
    #expect(try String(contentsOfFile: r.wt.path + "/a.txt", encoding: .utf8) == "hello\n")
    _ = try await r.call("git.stash", ["pop": true])
    #expect(try String(contentsOfFile: r.wt.path + "/a.txt", encoding: .utf8) == "changed\n")
    _ = try await r.call("git.discard", ["files": .array([.string("a.txt")])])
    #expect(try String(contentsOfFile: r.wt.path + "/a.txt", encoding: .utf8) == "hello\n")
}

@Test func lineStatsSplitCodeFromTests() async throws {
    let r = try await rig(); defer { r.d.stop() }
    try write(r, "a.txt", "hello\nmore\n")
    try FileManager.default.createDirectory(atPath: r.wt.path + "/tests", withIntermediateDirectories: true)
    try write(r, "tests/t.txt", "1\n2\n3\n")
    let s = try await r.c.call("git.lineStats", .obj(["id": .string(r.wt.id)]), as: LineStats.self)
    #expect(s.added[.code] == 1 && s.added[.tests] == 3)
}

@Test func archivingHidesADeskAndUnarchivingBringsItBack() async throws {
    let r = try await rig(); defer { r.d.stop() }
    _ = try await r.call("worktree.archive")
    #expect(FileManager.default.fileExists(atPath: r.wt.path))   // the folder stays: unarchiving finds it as it was
    let live = try await r.c.call("worktree.list", .obj(["repoId": .string(r.repo.id)]), as: [Worktree].self)
    #expect(!live.contains { $0.id == r.wt.id })   // not listed unless asked for
    let all = try await r.c.call("worktree.list", .obj(["repoId": .string(r.repo.id), "archived": true]), as: [Worktree].self)
    #expect(all.first { $0.id == r.wt.id }?.archived == true)
    _ = try await r.call("worktree.unarchive")
    let back = try await r.c.call("worktree.list", .obj(["repoId": .string(r.repo.id)]), as: [Worktree].self)
    #expect(back.contains { $0.id == r.wt.id })
}

@Test func commentStatesChangeAndOtherNamesFallBackToOpen() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let c: DiffComment = try await r.c.call("comment.add", .obj(["id": .string(r.wt.id), "file": "a.txt", "start": 1, "text": "fix"]), as: DiffComment.self)
    _ = try await r.c.call("comment.setState", .obj(["id": .string(c.id), "state": "resolved"]))
    #expect(try await r.c.call("comment.list", .obj(["id": .string(r.wt.id)]), as: [DiffComment].self).first?.state == .resolved)
    _ = try await r.c.call("comment.setState", .obj(["id": .string(c.id), "state": "nonsense"]))
    #expect(try await r.c.call("comment.list", .obj(["id": .string(r.wt.id)]), as: [DiffComment].self).first?.state == .open)
    await #expect(throws: (any Error).self) { _ = try await r.c.call("comment.setState", .obj(["id": "missing", "state": "open"])) }
}

@Test func projectSearchFindsTextInTheDesk() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let hits = try await r.call("files.search", ["query": "hello"]).array ?? []
    #expect(hits.first?["path"]?.string == "a.txt")
    #expect((try await r.call("files.search", ["query": "HELLO", "case": true]).array ?? []).isEmpty)
}

private func session(_ r: Rig, _ command: String) async throws -> Session {
    try await r.c.call("session.create", .obj(["worktreeId": .string(r.wt.id), "command": .string(command)]), as: Session.self)
}
private func sessions(_ r: Rig) async throws -> [Session] { try await r.c.call("session.list", as: [Session].self) }

@Test func unreadMarksFlipAndAnnotationsSetTheSummary() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let s = try await session(r, "cat")
    _ = try await r.c.call("session.markUnread", .obj(["id": .string(s.id)]))
    #expect(try await sessions(r).first { $0.id == s.id }?.unread == true)
    _ = try await r.c.call("session.markRead", .obj(["id": .string(s.id)]))
    #expect(try await sessions(r).first { $0.id == s.id }?.unread == false)
    _ = try await r.c.call("session.annotate", .obj(["id": .string(s.id), "summary": "Fixed the login bug"]))
    #expect(try await waitFor { try await sessions(r).first { $0.id == s.id }?.summary == "Fixed the login bug" })
    _ = try await r.c.call("session.annotate", .obj(["id": "no-such-session", "summary": "x"]))   // a session that is gone is not an error
}

@Test func writingToASessionReachesItsProgramAndAMissingOneIsRefused() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let s = try await session(r, "cat")
    _ = try await r.c.call("session.write", .obj(["id": .string(s.id), "base64": .string(Data("typed\n".utf8).base64EncodedString())]))
    #expect(try await waitFor { (try await r.c.call("session.read", .obj(["id": .string(s.id)]))).string?.contains("typed") == true })
    _ = try await r.c.call("session.write", .obj(["id": .string(s.id), "text": "plain\n"]))
    #expect(try await waitFor { (try await r.c.call("session.read", .obj(["id": .string(s.id)]))).string?.contains("plain") == true })
    await #expect(throws: (any Error).self) { _ = try await r.c.call("session.write", .obj(["id": "gone", "text": "x"])) }
}

@Test func aHookFromAnotherFolderIsWhereTheAgentWorksAndItsOwnFolderClearsIt() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let s = try await session(r, "cat")
    let elsewhere = r.wt.path + "/.claude/worktrees/fix"
    _ = try await r.c.call("session.hook", .obj(["id": .string(s.id), "event": "working", "cwd": .string(elsewhere)]))
    #expect(try await sessions(r).first { $0.id == s.id }?.currentDir == elsewhere)
    _ = try await r.c.call("session.hook", .obj(["id": .string(s.id), "event": "done", "cwd": .string(s.cwd + "/")]))
    #expect(try await sessions(r).first { $0.id == s.id }?.workDir == nil)
}

@Test func whatAProgramReportsShowsUntilItSaysSomethingElse() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let s = try await session(r, "printf '\\033]9;4;1;42\\007'; cat")   // ConEmu's progress bar, as cargo writes it
    #expect(try await waitFor { try await sessions(r).first { $0.id == s.id }?.progress == 42 })
    _ = try await r.c.call(SessionReport(id: s.id, state: "working", message: "Migrating the database", progress: 70))
    let working = try #require(try await sessions(r).first { $0.id == s.id })
    #expect(working.status == .working && working.summary == "Migrating the database" && working.progress == 70)
    _ = try await r.c.call(SessionReport(id: s.id, state: "done", message: "Deployed to staging"))
    #expect(try await waitFor { try await sessions(r).first { $0.id == s.id }.map { $0.status == .done && $0.progress == nil } == true })
    await #expect(throws: (any Error).self) { _ = try await r.c.call(SessionReport(id: s.id, state: "sleeping")) }
}

/// fx reports to herdr: the socket and pane come from its environment, the line is fx's own (a string id, no "jsonrpc").
@Test func anAgentReportingToHerdrReportsToKelp() async throws {
    let report = #"r() { zsocket $HERDR_SOCKET_PATH; print -u $REPLY "{\"id\":\"$1\",\"method\":\"pane.report_agent\",\"params\":"#
        + #"{\"pane_id\":\"$HERDR_PANE_ID\",\"source\":\"custom:fx\",\"agent\":\"fx\",\"state\":\"$2\"}}"; read -u $REPLY; exec {REPLY}>&-; }"#
    let fx = AgentManifest(id: "fx", name: "fx", command: "/bin/zsh", hooks: .herdr, resumeArgs: ["--continue"])
    var m = fx; m.args = ["-c", "zmodload zsh/net/socket; \(report); r 1 idle; echo ready; read; r 2 working; read; r 3 blocked; read; r 4 idle; cat"]
    let w = try await world(agents: [m]); defer { w.d.stop() }
    let s = try await w.c.call(SessionCreate(worktreeId: try await desk(w, "herdr").id, agent: "fx"))
    func status() async throws -> AgentStatus? { try await w.c.call(SessionList()).first { $0.id == s.id }?.status }
    func enter() async throws { _ = try await w.c.call(SessionWrite(id: s.id, base64: Data("\r".utf8).base64EncodedString())) }
    #expect(try await waitFor(10) { try await w.c.call(SessionRead(id: s.id)).contains("ready") })
    #expect(try await status() == .idle)   // idle before any work isn't a finished turn
    try await enter(); #expect(try await waitFor(5) { try await status() == .working })
    try await enter(); #expect(try await waitFor(5) { try await status() == .waiting })
    try await enter(); #expect(try await waitFor(5) { try await status() == .done })
    // A state herdr doesn't have is refused, whether or not the pane is still there.
    await #expect(throws: (any Error).self) { _ = try await w.c.call(PaneReportAgent(paneId: s.id, state: "done")) }
    await #expect(throws: (any Error).self) { _ = try await w.c.call(PaneReportAgent(paneId: "gone", state: "sleeping")) }
    _ = try await w.c.call(PaneReportAgent(paneId: s.id, state: "idle"))
    #expect(try await status() == .done)   // idle again after the turn: still finished
}

@Test func aCommandThatEndsKeepsItsExitCode() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let s = try await session(r, "exit 3")
    #expect(try await waitFor { try await sessions(r).first { $0.id == s.id }.map { $0.status == .exited && $0.exitCode == 3 } == true })
}

@Test func aSessionWithNoTurnYetHasNoTurnAndNoReply() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let s = try await session(r, "cat")
    let t = try await r.c.call("session.turn", .obj(["id": .string(s.id)]))
    #expect((t["turn"] ?? .null) == .null && t["hasBase"]?.bool == false)   // no turn: the key is left out (was null)
    #expect(try await r.c.call("session.lastReply", .obj(["id": .string(s.id)])) == .null)   // a plain command has no transcript
    #expect(try await r.c.call("session.turn", .obj(["id": "gone"])) == .null)
}

@Test func theScratchProjectIsMadeOnceAndReused() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let a = try await r.c.call("scratch.ensure", as: Worktree.self)
    let b = try await r.c.call("scratch.ensure", as: Worktree.self)
    #expect(a.id == b.id && FileManager.default.fileExists(atPath: a.path + "/.git"))
    #expect(try await r.c.call("repo.list", as: [Repo].self).filter { $0.name == "Scratch" }.count == 1)
}

@Test func relocatingAProjectPointsItsDeskAtTheNewFolder() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let moved = try makeRepo()
    let repo = try await r.c.call("repo.relocate", .obj(["id": .string(r.repo.id), "path": .string(moved)]), as: Repo.self)
    #expect(URL(fileURLWithPath: repo.path).resolvingSymlinksInPath().path == URL(fileURLWithPath: moved).resolvingSymlinksInPath().path)
    await #expect(throws: (any Error).self) {
        _ = try await r.c.call("repo.relocate", .obj(["id": .string(r.repo.id), "path": .string("/tmp/definitely-not-a-repo-\(UUID().uuidString)")]))
    }
}

@Test func aProjectTakesANameOfItsOwnAndAnEmptyOneGivesBackItsFolders() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let named = try await r.c.call("repo.rename", .obj(["id": .string(r.repo.id), "name": .string("  infra  ")]), as: Repo.self)
    #expect(named.name == "infra" && named.path == r.repo.path)
    let listed = try await r.c.call("repo.list", as: [Repo].self)
    #expect(listed.first { $0.id == r.repo.id }?.name == "infra")
    let back = try await r.c.call("repo.rename", .obj(["id": .string(r.repo.id), "name": .string(" ")]), as: Repo.self)
    #expect(back.name == (r.repo.path as NSString).lastPathComponent)
}

@Test func aRecipeFillsInTheBranchAndBase() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let text = try await r.call("recipe.render", ["name": .string("commit")]).string ?? ""
    #expect(!text.isEmpty && !text.contains("{"))   // every placeholder was filled
}

@Test func pushGoesToTheUpstreamAndFailsClearlyWithoutOne() async throws {
    let r = try await rig(); defer { r.d.stop() }
    await #expect(throws: (any Error).self) { _ = try await r.call("git.push") }   // no remote at all
    let bare = tmp().path
    try Git.run(["init", "-q", "--bare", "-b", "main"], cwd: bare)
    try Git.run(["remote", "add", "origin", bare], cwd: r.wt.path)
    try Git.run(["push", "-q", "-u", "origin", "feat/x"], cwd: r.wt.path)
    try write(r, "n.txt", "n\n")
    try Git.run(["add", "n.txt"], cwd: r.wt.path); try Git.run(["commit", "-qm", "more"], cwd: r.wt.path)
    _ = try await r.call("git.push")
    #expect(try Git.run(["rev-parse", "feat/x"], cwd: bare) == (try Git.run(["rev-parse", "HEAD"], cwd: r.wt.path)))
}

@Test func cloneNamesAndNewFoldersAreChecked() throws {
    #expect(RepoClone.folderName("git@github.com:me/app.git") == "app")
    #expect(RepoClone.folderName("https://gitlab.com/me/app/") == "app")
    #expect(RepoClone.folderName("  https://x.org/me/tool.git \n") == "tool")
    #expect(RepoClone.folderName("") == "")
    let parent = tmp().path
    #expect(try Forges.newFolder("  proj ", in: parent) == parent + "/proj")
    for bad in ["", "a/b", ".hidden"] { #expect(throws: (any Error).self) { try Forges.newFolder(bad, in: parent) } }
    #expect(throws: (any Error).self) { try Forges.newFolder("x", in: parent + "/missing") }   // the parent must exist
    try FileManager.default.createDirectory(atPath: parent + "/taken", withIntermediateDirectories: true)
    #expect(throws: (any Error).self) { try Forges.newFolder("taken", in: parent) }
}

@Test func agentVersionsAreTheFirstSemver() throws {
    #expect(Sessions.semver("claude 2.1.3 (Claude Code)") == "2.1.3")
    #expect(Sessions.semver("codex-cli v0.4.12-beta") == "0.4.12")
    #expect(Sessions.semver("version 3.1") == nil && Sessions.semver("") == nil)
}

/// A program in one session reports only that session's status: an agent can't mark another one done or asking. From
/// outside every session (the app, the CLI in a terminal elsewhere), any.
@Test func aSessionReportsOnlyItsOwnStatus() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let other = try await session(r, "cat")
    let say = #"r() { zsocket $KELP_SOCKET; print -u $REPLY "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.report\",\"params\":"#
        + #"{\"id\":\"$1\",\"state\":\"$2\"}}"; read -u $REPLY line; print -r -- "$line"; exec {REPLY}>&-; }"#
    let me = try await session(r, "/bin/zsh -c 'zmodload zsh/net/socket; \(say); r \(other.id) blocked; r $KELP_SESSION done; cat'")
    #expect(try await waitFor(10) { try await sessions(r).first { $0.id == me.id }?.status == .done })
    #expect(try await r.c.call(SessionRead(id: me.id)).contains("only its own status"))
    #expect(try await sessions(r).first { $0.id == other.id }?.status != .waiting)
    _ = try await r.c.call(SessionReport(id: other.id, state: "blocked"))   // this test process is in no session
    #expect(try await waitFor { try await sessions(r).first { $0.id == other.id }?.status == .waiting })
}

/// An agent that ended unread is read at a glance too: its record, as it isn't live any more.
@Test func anEndedSessionCanBeMarkedRead() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let s = try await session(r, "true")
    #expect(try await waitFor { try await sessions(r).first { $0.id == s.id }?.status == .exited })
    _ = try await r.c.call("session.markUnread", .obj(["id": .string(s.id)]))
    #expect(try await sessions(r).first { $0.id == s.id }?.unread == true)
    _ = try await r.c.call("session.markRead", .obj(["id": .string(s.id)]))
    #expect(try await sessions(r).first { $0.id == s.id }?.unread == false)
}

/// Whatever a `kelp attach` sends right behind its session.stream line, in the same write, reaches the session: the
/// lines after it are the stream's as much as the bytes after the last line end.
@Test func linesRightAfterAStreamRequestReachTheSession() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let s = try await session(r, "cat")
    let fd = try Unix.connect(r.d.socketPath)
    defer { close(fd) }
    let start = #"{"jsonrpc":"2.0","method":"session.stream","params":{"id":"\#(s.id)"}}"# + "\nfirst-line\nsecond"
    #expect(Unix.writeAll(fd, Data(start.utf8)))
    #expect(try await waitFor { try await r.c.call(SessionRead(id: s.id)).contains("first-line") })
}
