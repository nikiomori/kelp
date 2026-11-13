import Agents
import Core
import Foundation
import GitKit
import Testing
import os

@testable import Daemon

/// Every notification a client heard, in order.
private final class Heard: Sendable {
    private let all = OSAllocatedUnfairLock<[(String, JSONValue)]>(initialState: [])
    func listen(_ c: RPCClient) { c.onNotification = { [self] m, p in all.withLock { $0.append((m, p)) } } }
    func events<E: RPCEvent>(_: E.Type) -> [E] {
        all.withLock { $0 }.filter { $0.0 == E.name }.compactMap { try? $0.1.decode(E.self) }
    }
}

/// A watched workspace's git comes at once, then again when its files change — and not again while nothing does.
/// Before, every panel had a watcher of its own and asked git again itself.
@Test func aWatchedWorkspacesGitIsPushedWhenItsFilesChangeAndOnlyThen() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let heard = Heard()
    heard.listen(w.c)
    w.c.notify(WatchStart(.git, wt.id))
    #expect(try await waitFor(10) { heard.events(GitEvent.self).first?.changes == [] })
    try "new\n".write(toFile: wt.path + "/added.txt", atomically: true, encoding: .utf8)
    #expect(try await waitFor(10) { heard.events(GitEvent.self).last?.changes?.map(\.path) == ["added.txt"] })
    let seen = heard.events(GitEvent.self).count
    let key = Watches.Key(topic: .git, key: wt.id), reads = { w.d.watches.reads.withLock { $0?[key] ?? 0 } }
    let before = reads()
    try "new\n".write(toFile: wt.path + "/added.txt", atomically: true, encoding: .utf8)   // as it was: the same status
    #expect(try await waitFor(10) { reads() > before })
    _ = try await w.c.call(Ping())   // what that read pushed would have come before this answer
    #expect(heard.events(GitEvent.self).count == seen)   // nothing changes: nothing is pushed
}

/// A build writing into a folder git ignores (dist/) doesn't read git again; once .gitignore stops ignoring it, it does.
@Test func whatGitIgnoresDoesntReadGitAgain() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let key = Watches.Key(topic: .git, key: wt.id)
    let heard = Heard()
    heard.listen(w.c)
    try "dist/\n".write(toFile: wt.path + "/.gitignore", atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(atPath: wt.path + "/dist/js", withIntermediateDirectories: true)
    w.c.notify(WatchStart(.git, wt.id))
    #expect(try await waitFor(10) { heard.events(GitEvent.self).first?.changes?.map(\.path) == [".gitignore"] })
    // Judged by hand, as the watch judges its events: no event says a dropped one was seen, and a read counted after
    // a wait says nothing of which event made it.
    let (_, matters) = try #require(w.d.topic(key).folder)
    let built = wt.path + "/dist/js/a.js"
    #expect(matters([wt.path + "/src.txt"]) && !matters([built]) && !matters([built, wt.path + "/dist/b.js"]))
    #expect(matters([built, wt.path + "/src.txt"]))   // one that counts among those that don't
    for i in 0..<5 { try "\(i)\n".write(toFile: built, atomically: true, encoding: .utf8) }
    try "\n".write(toFile: wt.path + "/.gitignore", atomically: true, encoding: .utf8)
    #expect(matters([wt.path + "/.gitignore"]) && matters([built]))   // the rules changed: asked again
    #expect(
        try await waitFor(10) {
            heard.events(GitEvent.self).last?.changes?.contains { $0.path.hasPrefix("dist/") } == true
        })
}

/// A session's records come with rising revisions, and the reply that created it is older than all of them: an app that
/// gets the reply after an event keeps what the event said.
@Test func aSessionsRecordsComeWithRisingRevisions() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let heard = Heard()
    heard.listen(w.c)
    let s = try await w.c.call(SessionCreate(worktreeId: wt.id, command: "echo hi; exec sleep 30"))
    _ = try await w.c.call(SessionRename(id: s.id, title: "named"))
    #expect(try await waitFor(10) { heard.events(Session.self).contains { $0.id == s.id && $0.title == "named" } })
    let revisions = heard.events(Session.self).filter { $0.id == s.id }.compactMap(\.revision)
    #expect(revisions == revisions.sorted() && Set(revisions).count == revisions.count)
    #expect((s.revision ?? 0) >= 1 && revisions.allSatisfy { $0 > s.revision ?? 0 })
}

@Test func aPathIsInTheFoldersAboveIt() {
    #expect(IgnoredFolders.folders("a/b/c.txt") == ["a/", "a/b/"])
    #expect(IgnoredFolders.folders("c.txt").isEmpty && IgnoredFolders.folders(".git/index").isEmpty)
}

/// Two clients watching one topic share one reader; it stops after the last one stops watching or goes away.
@Test func watchersShareOneReaderThatStopsWithTheLast() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let a = try client(w.root), b = try client(w.root)
    let ha = Heard(), hb = Heard()
    ha.listen(a)
    hb.listen(b)
    a.notify(WatchStart(.ports, wt.id))
    b.notify(WatchStart(.ports, wt.id))
    #expect(try await waitFor(10) { !ha.events(PortsEvent.self).isEmpty && !hb.events(PortsEvent.self).isEmpty })
    #expect(w.d.watches.count == 1)
    a.notify(WatchStop(.ports, wt.id))
    _ = try await b.call(Ping())   // after b's own connection was taken; a's stop is on its way
    #expect(try await waitFor(5) { w.d.watches.count == 1 })
    b.close()
    #expect(try await waitFor(5) { w.d.watches.count == 0 })
    let key = Watches.Key(topic: .ports, key: wt.id)
    let reads = w.d.watches.reads.withLock { $0?[key] ?? 0 }
    // A ports reader reads every 3 s while anyone watches: once one started after the stop has been read twice, the
    // stopped one's next read was due.
    let probe = Watches.Key(topic: .ports, key: "probe")
    w.c.notify(WatchStart(.ports, probe.key))
    #expect(try await waitFor(10) { w.d.watches.reads.withLock { $0?[probe] ?? 0 } >= 2 })
    #expect(w.d.watches.reads.withLock { $0?[key] ?? 0 } == reads)
}

/// Projects and workspaces come as records when they change, including a workspace the list itself added, and removals say
/// so: the app keeps its lists from these instead of reading them again on "something changed".
@Test func recordsArePushedAsTheyChange() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let heard = Heard()
    heard.listen(w.c)
    let wt = try await firstWorkspace(w)
    _ = try await w.c.call(WorktreeNote(id: wt.id, note: "Renamed"))
    #expect(try await waitFor(5) { heard.events(Worktree.self).contains { $0.id == wt.id && $0.note == "Renamed" } })
    let other = try await w.c.call(RepoAdd(path: try makeRepo()))   // its first workspace is made by the workspace sync
    #expect(try await waitFor(5) { heard.events(Repo.self).contains { $0.id == other.id } })
    #expect(try await waitFor(5) { heard.events(Worktree.self).contains { $0.repoId == other.id } })
    let workspace = try await w.c.call(WorkspaceCreate(repoId: w.repo.id))
    _ = try await w.c.call(WorktreeRemove(id: workspace.id))
    #expect(try await waitFor(5) { heard.events(RemovedEvent.self).contains { $0.worktree == workspace.id } })
    _ = try await w.c.call(RepoRemove(id: other.id))
    #expect(try await waitFor(5) { heard.events(RemovedEvent.self).contains { $0.repo == other.id } })
}

/// A session deleted for good (here with its workspace) says so too: the app drops it without reading the list again.
@Test func aDeletedSessionIsPushedAsRemoved() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let heard = Heard()
    heard.listen(w.c)
    let workspace = try await w.c.call(WorkspaceCreate(repoId: w.repo.id))
    let s = try await w.c.call(SessionCreate(worktreeId: workspace.id, command: "exec cat"))
    _ = try await w.c.call(WorktreeRemove(id: workspace.id))
    #expect(try await waitFor(5) { heard.events(RemovedEvent.self).contains { $0.session == s.id } })
}

/// A watch stopped and started again while its first read was still out: that read, finishing last, says nothing. It
/// used to be taken for the new watch's and pushed after the newer value, leaving the app with the old one.
@Test func aReadFromBeforeAStopIsNotPushedAfterTheNewerOne() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let heard = Heard()
    heard.listen(w.c)
    let reads = OSAllocatedUnfairLock(initialState: 0), release = OSAllocatedUnfairLock(initialState: false)
    @Sendable func line(_ used: Int) -> Data? {
        try? Wire.line(RPCNotification(ContextEvent(session: "s", usage: .init(used: used, window: 9))))
    }
    w.d.watches.reading.withLock {
        $0.topic = { _ in
            Watches.Topic { _ in
                guard
                    reads.withLock({
                        $0 += 1
                        return $0
                    }) == 1
                else { return (line(2), nil) }
                _ = try? await waitFor(10) { release.withLock { $0 } }
                return (line(1), nil)   // the first read, from before the stop
            }
        }
    }
    w.c.notify(WatchStart(.context, "s"))
    #expect(try await waitFor(5) { reads.withLock { $0 } == 1 })
    w.c.notify(WatchStop(.context, "s"))
    w.c.notify(WatchStart(.context, "s"))
    #expect(try await waitFor(5) { heard.events(ContextEvent.self).last?.usage?.used == 2 })
    release.withLock { $0 = true }
    #expect(try await waitFor(5) { w.d.watches.reads.withLock { $0?[.init(topic: .context, key: "s")] } == 2 })
    _ = try await w.c.call(Ping())   // what the old read pushed would have come before this answer
    #expect(heard.events(ContextEvent.self).map { $0.usage?.used } == [2])
}

/// A watched file's version is pushed as it changes and when it goes: the stamp `files.read` gives, nil once removed. A
/// touch is a new version (the app reads the text then, and finds it the same); a file next to it changing says nothing.
/// Two clients watching it share one watch.
@Test func aWatchedFilesVersionIsPushedAsItChangesAndGoes() async throws {
    let (d, c, root) = try daemon()
    defer { d.stop() }
    let dir = tmp().path, path = dir + "/a.txt"
    try "one".write(toFile: path, atomically: true, encoding: .utf8)
    let heard = Heard()
    heard.listen(c)
    let other = try client(root), hearsToo = Heard()
    hearsToo.listen(other)
    c.notify(WatchStart(.file, path))
    other.notify(WatchStart(.file, path))
    func stamps() -> [FileStamp?] { heard.events(FileEvent.self).map(\.stamp) }
    let first = try await c.call(FilesRead(path: path)).stamp
    #expect(try await waitFor(10) { stamps() == [first] && hearsToo.events(FileEvent.self).map(\.stamp) == [first] })
    #expect(d.watches.count == 1)
    try "two".write(toFile: path, atomically: true, encoding: .utf8)
    let second = try await c.call(FilesRead(path: path)).stamp
    #expect(try await waitFor(10) { stamps() == [first, second] })
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: path)
    #expect(try await waitFor(10) { stamps().count == 3 && stamps().last != second })
    try "b".write(toFile: dir + "/b.txt", atomically: true, encoding: .utf8)   // its neighbour
    try FileManager.default.removeItem(atPath: path)
    #expect(try await waitFor(10) { stamps().last == .some(nil) })
    #expect(stamps().count == 4)   // nothing came for the neighbour before it
}

/// A workspace's files are pushed when the list changes, once; a file's text changing leaves the list as it was.
@Test func aWorkspacesFilesArePushedWhenTheListChanges() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let heard = Heard()
    heard.listen(w.c)
    w.c.notify(WatchStart(.files, wt.id))
    let listed = try await w.c.call(FilesList(id: wt.id))
    #expect(try await waitFor(10) { heard.events(FilesEvent.self).map(\.paths) == [listed] })
    try "new\n".write(toFile: wt.path + "/added.txt", atomically: true, encoding: .utf8)
    #expect(try await waitFor(10) { heard.events(FilesEvent.self).last?.paths?.contains("added.txt") == true })
    try "changed\n".write(toFile: wt.path + "/added.txt", atomically: true, encoding: .utf8)
    #expect(
        try await waitFor(10) { w.d.watches.reads.withLock { $0?[Watches.Key(topic: .files, key: wt.id)] ?? 0 } >= 3 })   // read again…
    _ = try await w.c.call(Ping())   // (counted before it's compared and pushed: a push would come before this answer)
    #expect(heard.events(FilesEvent.self).count == 2)   // …not pushed, and the new file's list once
}

@Test func whatChangesAFileList() {
    #expect(
        Git.touchesFileList(["/r/src/a.swift"]) && Git.touchesFileList(["/r/.git/index"])
            && Git.touchesFileList(["/r/.git/HEAD"]))
    #expect(!Git.touchesFileList(["/r/.git/objects/ab/cd", "/r/.git/logs/HEAD", "/r/.git"]))
}

/// Once the daemon stopped following folders, a project written after that (a late request) doesn't start watching
/// its .git again: it did, from the store's change hook on whatever thread wrote.
@Test func aProjectWrittenAfterStopIsntWatched() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    d.workspaces.stopWatching()
    _ = try await c.call("repo.add", .obj(["path": .string(try makeRepo())]))
    d.workspaces.headQueue.sync {}
    #expect(d.workspaces.heads.withLock { $0 ?? [:] }.isEmpty)
}

/// An agent's Bash commands, as its hooks tell them: in its list, pushed to whoever watches it; the one running on its
/// row; one whose end never came, stopped when its turn ends.
@Test func anAgentsCommandsAreListedAndTheRunningOneIsOnItsRow() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let s: Session = try await w.c.call(
        "session.create", .obj(["worktreeId": .string(wt.id), "command": "sleep 30"]), as: Session.self)
    let heard = Heard()
    heard.listen(w.c)
    w.c.notify(WatchStart(.commands, s.id))
    func hook(_ c: AgentCommand) async throws {
        _ = try await w.c.call(SessionHook(id: s.id, event: "command", command: c))
    }
    func row() async throws -> Session? {
        try await w.c.call("session.list", as: [Session].self).first { $0.id == s.id }
    }
    func pushed() -> [AgentCommand]? { heard.events(CommandsEvent.self).last?.commands }
    try await hook(AgentCommand(id: "a", command: "swift test"))
    #expect(try await waitFor(10) { try await row()?.running == "swift test" })
    #expect(try await waitFor(10) { pushed()?.map(\.id) == ["a"] })
    try await hook(
        AgentCommand(
            id: "a", command: "swift test", started: Date(), ended: Date(), outcome: .failed, exitCode: 1,
            output: "1 failed"))
    #expect(try await waitFor(10) { try await row()?.running == nil })
    try await hook(AgentCommand(id: "b", command: "rm -rf build"))   // its permission denied: no end comes
    #expect(try await waitFor(10) { try await row()?.running == "rm -rf build" })
    _ = try await w.c.call("session.hook", .obj(["id": .string(s.id), "event": "done"]))
    #expect(try await waitFor(10) { pushed()?.map(\.outcome) == [.failed, .stopped] })
    #expect(try await row()?.running == nil)
    let list = try await w.c.call(SessionCommands(id: s.id))
    #expect(list.first?.exitCode == 1 && list.first?.output == "1 failed")
}

/// What's asked over the network slows down while nothing changes, up to a ceiling; a CI run going on and the local
/// clocks don't.
@Test func pollsOfTheNetworkSlowDownWhileNothingChanges() throws {
    let d = try Daemon(root: tmp())
    func slowed(_ topic: WatchTopic, _ next: TimeInterval, quiet: Int) -> TimeInterval {
        Watches.slowed(next, quiet: quiet, from: d.topic(.init(topic: topic, key: "x")).backsOffFrom)
    }
    #expect(slowed(.pr, 60, quiet: 0) == 60)
    #expect(slowed(.pr, 60, quiet: 1) == 120)
    #expect(slowed(.pr, 60, quiet: 50) == 480)
    #expect(slowed(.ci, 120, quiet: 3) == 960)
    #expect(slowed(.ci, 10, quiet: 9) == 10)
    #expect(slowed(.git, 10, quiet: 9) == 60)
    #expect(slowed(.ports, 3, quiet: 9) == 3)
    #expect(slowed(.limits, 10, quiet: 9) == 10)
}

/// Whoever looks at a subagent hears of its next step; a transcript says nothing of itself, so the topic reads it.
@Test func aSubagentsStepsArePushedToWhoWatches() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let s: Session = try await w.c.call(
        "session.create", .obj(["worktreeId": .string(wt.id), "command": "sleep 30"]), as: Session.self)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let folder = dir.appendingPathComponent("0F/subagents")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let line =
        #"{"type":"assistant","timestamp":"2026-11-02T06:25:15.000Z","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a.swift"}}]}}"#
    try Data((line + "\n").utf8).write(to: folder.appendingPathComponent("agent-a1.jsonl"))
    _ = try await w.c.call(
        SessionHook(id: s.id, event: "working", transcript: dir.appendingPathComponent("0F.jsonl").path))
    let heard = Heard()
    heard.listen(w.c)
    w.c.notify(WatchStart(.subagents, s.id))
    #expect(try await waitFor(10) { heard.events(SubagentsEvent.self).last?.steps.isEmpty == true })
    _ = try await w.c.call(SessionHook(id: s.id, event: "subagent", hookName: "SubagentStart", agentId: "a1"))
    #expect(try await waitFor(10) { heard.events(SubagentsEvent.self).last?.steps["a1"]?.step.tool == "Read" })
}

/// A workspace's artifacts are pushed as its `.kelp/artifacts` changes; its other files don't read them again.
@Test func aWorkspacesArtifactsArePushedAsTheyChange() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let heard = Heard()
    heard.listen(w.c)
    w.c.notify(WatchStart(.artifacts, wt.id))
    #expect(try await waitFor(10) { heard.events(ArtifactsEvent.self).map(\.items) == [[]] })
    _ = try Artifacts.create(.doc, title: "Plan", root: wt.path, session: nil)
    #expect(try await waitFor(10) { heard.events(ArtifactsEvent.self).last?.items.map(\.title) == ["Plan"] })
    // Judged by hand, as the watch judges its events: no event says a dropped one was seen.
    let (_, matters) = try #require(w.d.topic(Watches.Key(topic: .artifacts, key: wt.id)).folder)
    #expect(!matters([wt.path + "/other.txt"]) && matters([wt.path + "/\(Artifacts.folder)/plan/index.md"]))
}

/// The daemon as it runs keeps no count of reads: one per key ever watched would only grow. Tests turn it on.
@Test func aRunningDaemonCountsNoReads() throws {
    let d = try Daemon(root: tmp())
    #expect(d.watches.reads.withLock { $0 } == nil)
}

/// A folder on a branch of its own says what the branch committed since its base, for the files another folder changes
/// too; the project's own folder, on the base, says nothing of it.
@Test func aBranchsGitSaysWhatItCommittedSinceItsBase() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let base = try await firstWorkspace(w)
    let fix = try await w.c.call(WorktreeCreate(repoId: base.repoId, branch: "fix", setup: false)).worktree
    try "x\n".write(toFile: fix.path + "/login.swift", atomically: true, encoding: .utf8)
    try Git.run(["add", "login.swift"], cwd: fix.path, remotes: .none)
    try Git.run(["commit", "-qm", "login"], cwd: fix.path, remotes: .none)
    let heard = Heard()
    heard.listen(w.c)
    w.c.notify(WatchStart(.git, fix.id))
    w.c.notify(WatchStart(.git, base.id))
    func event(_ id: String) -> GitEvent? { heard.events(GitEvent.self).last { $0.worktree == id } }
    #expect(try await waitFor(10) { event(fix.id)?.branchFiles == ["login.swift"] })
    #expect(try await waitFor(10) { event(base.id)?.changes != nil })
    #expect(event(base.id)?.branchFiles == nil)
}

/// A remote project's Claude Code publishes on the host, where no hook of Kelp's runs: the pages its conversation there
/// names join the list in the project's folder here, each once, timed as the host stamped them, a file sent from the
/// host left uncopied; another chat's stay its own.
@Test func pagesPublishedOnAHostAreListed() async throws {
    _ = localSSH
    var claude = AgentManifest(id: "claude", name: "Claude Code", command: "/bin/bash", args: ["-c", "sleep 30", "x"])
    claude.sessionIdFlag = "--session-id"
    claude.resumeIdFlag = "--resume"
    let (d, c, _) = try daemon(agents: [claude])
    defer { d.stop() }
    let there = try makeRepo(), host = tmp()
    d.agentUsage.conversations.hostClaude.withLock { $0 = ShellQuote.word(host.path) }
    let repo: Repo = try await c.call("repo.addRemote", .obj(["host": "box", "path": .string(there)]), as: Repo.self)
    let workspace = try #require(try await c.call("worktree.list", as: [Worktree].self).first { $0.repoId == repo.id })
    let session = try await c.call(SessionCreate(worktreeId: workspace.id, agent: "claude"))
    let folder = host.appendingPathComponent(
        "projects/" + (try #require(Paths.real(there))).replacing(/[^A-Za-z0-9]/, with: "-"))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let transcript = folder.appendingPathComponent(session.id.lowercased() + ".jsonl")
    func call(_ id: String, _ tool: String, _ input: String, at: String) -> String {
        #"{"type":"assistant","timestamp":"\#(at)","message":{"content":[{"type":"tool_use","id":"\#(id)","#
            + #""name":"mcp__claude-artifacts__\#(tool)","input":\#(input)}]}}"#
    }
    func answer(_ id: String, _ url: String, at: String) -> String {
        #"{"type":"user","timestamp":"\#(at)","message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)","#
            + #""content":[{"type":"text","text":"{\"url\":\"\#(url)\"}"}]}]}}"#
    }
    func append(_ lines: [String]) throws {
        let old = (try? String(contentsOf: transcript, encoding: .utf8)) ?? ""
        try (old + lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
    }
    let plan = "https://claude.ai/artifact/plan", files = "https://claude.ai/artifact/files"
    try append([
        #"{"type":"user","timestamp":"2026-11-13T10:00:00.000Z","message":{"content":"make a plan"}}"#,
        call("a", "publish_version", #"{"title":"Plan","content":"<p>one</p>"}"#, at: "2026-11-13T10:00:05.000Z"),
        answer("a", plan, at: "2026-11-13T10:00:07.250Z"),
        call(
            "b", "publish_files", #"{"title":"Files","files":[{"as":"index.html","path":"/etc/hosts"}]}"#,
            at: "2026-11-13T10:00:08.000Z"),
        answer("b", files, at: "2026-11-13T10:00:09.000Z")
    ])
    let heard = Heard()
    heard.listen(c)
    c.notify(WatchStart(.artifacts, workspace.id))   // the panel shows: its list asks the host
    #expect(try await waitFor(10) { heard.events(ArtifactsEvent.self).last?.items.map(\.title) == ["Files", "Plan"] })
    var items = Artifacts.items(root: workspace.path)
    #expect(items.map(\.url) == [files, plan])
    #expect(items.allSatisfy { $0.session == session.id })
    #expect(items[1].created == (try Date("2026-11-13T10:00:07Z", strategy: .iso8601)).timeIntervalSince1970)
    #expect(items[0].preview == nil, "its file is on the host: /etc/hosts here is another file")
    #expect(try String(contentsOfFile: try #require(items[1].preview), encoding: .utf8) == "<p>one</p>")

    try await Task.sleep(for: .seconds(1))   // the reads its own writes start are over
    // A later turn edits it: its end reads the list again; the edit is applied once, however often that happens.
    try append([
        call(
            "c", "edit_version", #"{"edits":[{"old_text":"one","new_text":"one one"}]}"#,
            at: "2026-11-13T10:05:00.000Z"),
        answer("c", plan, at: "2026-11-13T10:05:01.000Z")
    ])
    d.sessions.keepArtifactVersions(session: session.id, worktree: workspace.id, prompt: "edit it")
    #expect(try await waitFor(10) { heard.events(ArtifactsEvent.self).last?.items.first?.url == plan })
    d.sessions.keepArtifactVersions(session: session.id, worktree: workspace.id, prompt: "again")
    try await Task.sleep(for: .seconds(1))   // that read, too
    items = Artifacts.items(root: workspace.path)
    #expect(items.count == 2 && items[0].url == plan)
    #expect(try String(contentsOfFile: try #require(items[0].preview), encoding: .utf8) == "<p>one one</p>")
    _ = try await c.call(SessionKill(id: session.id))   // its tmux session on the "host" ends with it
}
