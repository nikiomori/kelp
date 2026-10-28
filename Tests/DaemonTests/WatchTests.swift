import Foundation
import os
import Testing
import Core
@testable import Daemon

/// Every notification a client heard, in order.
private final class Heard: Sendable {
    private let all = OSAllocatedUnfairLock<[(String, JSONValue)]>(initialState: [])
    func listen(_ c: RPCClient) { c.onNotification = { [self] m, p in all.withLock { $0.append((m, p)) } } }
    func events<E: RPCEvent>(_: E.Type) -> [E] { all.withLock { $0 }.filter { $0.0 == E.name }.compactMap { try? $0.1.decode(E.self) } }
}

/// A watched workspace's git comes at once, then again when its files change — and not again while nothing does.
/// Before, every panel had a watcher of its own and asked git again itself.
@Test func aWatchedWorkspacesGitIsPushedWhenItsFilesChangeAndOnlyThen() async throws {
    let w = try await world(); defer { w.d.stop() }
    let wt = try await firstDesk(w)
    let heard = Heard(); heard.listen(w.c)
    w.c.notify(WatchStart(.git, wt.id))
    #expect(try await waitFor(10) { heard.events(GitEvent.self).first?.changes == [] })
    try "new\n".write(toFile: wt.path + "/added.txt", atomically: true, encoding: .utf8)
    #expect(try await waitFor(10) { heard.events(GitEvent.self).last?.changes?.map(\.path) == ["added.txt"] })
    let seen = heard.events(GitEvent.self).count
    try await Task.sleep(for: .milliseconds(1500))   // nothing changes: nothing is pushed
    #expect(heard.events(GitEvent.self).count == seen)
}

/// A build writing into a folder git ignores (dist/) doesn't read git again; once .gitignore stops ignoring it, it does.
@Test func whatGitIgnoresDoesntReadGitAgain() async throws {
    let w = try await world(); defer { w.d.stop() }
    let wt = try await firstDesk(w)
    let key = Watches.Key(topic: .git, key: wt.id)
    func reads() -> Int { w.d.watches.reads.withLock { $0[key] ?? 0 } }
    let heard = Heard(); heard.listen(w.c)
    try "dist/\n".write(toFile: wt.path + "/.gitignore", atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(atPath: wt.path + "/dist/js", withIntermediateDirectories: true)
    w.c.notify(WatchStart(.git, wt.id))
    #expect(try await waitFor(10) { heard.events(GitEvent.self).first?.changes?.map(\.path) == [".gitignore"] })
    try await Task.sleep(for: .milliseconds(800))
    let before = reads()
    for i in 0..<5 { try "\(i)\n".write(toFile: wt.path + "/dist/js/a.js", atomically: true, encoding: .utf8); try await Task.sleep(for: .milliseconds(150)) }
    try await Task.sleep(for: .milliseconds(1200))
    #expect(reads() == before)
    try "\n".write(toFile: wt.path + "/.gitignore", atomically: true, encoding: .utf8)
    #expect(try await waitFor(10) { heard.events(GitEvent.self).last?.changes?.contains { $0.path.hasPrefix("dist/") } == true })
}

/// A session's records come with rising revisions, and the reply that created it is older than all of them: an app that
/// gets the reply after an event keeps what the event said.
@Test func aSessionsRecordsComeWithRisingRevisions() async throws {
    let w = try await world(); defer { w.d.stop() }
    let wt = try await firstDesk(w)
    let heard = Heard(); heard.listen(w.c)
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
    let w = try await world(); defer { w.d.stop() }
    let wt = try await firstDesk(w)
    let a = try client(w.root), b = try client(w.root)
    let ha = Heard(), hb = Heard(); ha.listen(a); hb.listen(b)
    a.notify(WatchStart(.ports, wt.id)); b.notify(WatchStart(.ports, wt.id))
    #expect(try await waitFor(10) { !ha.events(PortsEvent.self).isEmpty && !hb.events(PortsEvent.self).isEmpty })
    #expect(w.d.watches.running == 1)
    a.notify(WatchStop(.ports, wt.id))
    _ = try await b.call(Ping())   // after b's own connection was taken; a's stop is on its way
    #expect(try await waitFor(5) { w.d.watches.running == 1 })
    b.close()
    #expect(try await waitFor(5) { w.d.watches.running == 0 })
    let key = Watches.Key(topic: .ports, key: wt.id)
    let reads = w.d.watches.reads.withLock { $0[key] ?? 0 }
    try await Task.sleep(for: .seconds(4))   // a ports reader reads every 3 s while anyone watches
    #expect(w.d.watches.reads.withLock { $0[key] ?? 0 } == reads)
}

/// Projects and workspaces come as records when they change, including a desk the list itself added, and removals say
/// so: the app keeps its lists from these instead of reading them again on "something changed".
@Test func recordsArePushedAsTheyChange() async throws {
    let w = try await world(); defer { w.d.stop() }
    let heard = Heard(); heard.listen(w.c)
    let wt = try await firstDesk(w)
    _ = try await w.c.call(WorktreeNote(id: wt.id, note: "Renamed"))
    #expect(try await waitFor(5) { heard.events(Worktree.self).contains { $0.id == wt.id && $0.note == "Renamed" } })
    let other = try await w.c.call(RepoAdd(path: try makeRepo()))   // its first desk is made by the desk sync
    #expect(try await waitFor(5) { heard.events(Repo.self).contains { $0.id == other.id } })
    #expect(try await waitFor(5) { heard.events(Worktree.self).contains { $0.repoId == other.id } })
    let desk = try await w.c.call(WorkspaceCreate(repoId: w.repo.id))
    _ = try await w.c.call(WorktreeRemove(id: desk.id))
    #expect(try await waitFor(5) { heard.events(RemovedEvent.self).contains { $0.worktree == desk.id } })
    _ = try await w.c.call(RepoRemove(id: other.id))
    #expect(try await waitFor(5) { heard.events(RemovedEvent.self).contains { $0.repo == other.id } })
}

/// A session deleted for good (here with its workspace) says so too: the app drops it without reading the list again.
@Test func aDeletedSessionIsPushedAsRemoved() async throws {
    let w = try await world(); defer { w.d.stop() }
    let heard = Heard(); heard.listen(w.c)
    let desk = try await w.c.call(WorkspaceCreate(repoId: w.repo.id))
    let s = try await w.c.call(SessionCreate(worktreeId: desk.id, command: "exec cat"))
    _ = try await w.c.call(WorktreeRemove(id: desk.id))
    #expect(try await waitFor(5) { heard.events(RemovedEvent.self).contains { $0.session == s.id } })
}

/// A watch stopped and started again while its first read was still out: that read, finishing last, says nothing. It
/// used to be taken for the new watch's and pushed after the newer value, leaving the app with the old one.
@Test func aReadFromBeforeAStopIsNotPushedAfterTheNewerOne() async throws {
    let w = try await world(); defer { w.d.stop() }
    let heard = Heard(); heard.listen(w.c)
    let reads = OSAllocatedUnfairLock(initialState: 0), release = OSAllocatedUnfairLock(initialState: false)
    @Sendable func line(_ used: Int) -> Data? { try? Wire.line(RPCNotification(ContextEvent(session: "s", usage: .init(used: used, window: 9)))) }
    w.d.watches.reading.withLock {
        $0.read = { _, _ in
            guard reads.withLock({ $0 += 1; return $0 }) == 1 else { return (line(2), nil) }
            while !release.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(10)) }
            return (line(1), nil)   // the first read, from before the stop
        }
    }
    w.c.notify(WatchStart(.context, "s"))
    #expect(try await waitFor(5) { reads.withLock { $0 } == 1 })
    w.c.notify(WatchStop(.context, "s")); w.c.notify(WatchStart(.context, "s"))
    #expect(try await waitFor(5) { heard.events(ContextEvent.self).last?.usage?.used == 2 })
    release.withLock { $0 = true }
    try await Task.sleep(for: .milliseconds(500))
    #expect(heard.events(ContextEvent.self).map { $0.usage?.used } == [2])
}

/// A watched file's version is pushed as it changes and when it goes: the stamp `files.read` gives, nil once removed. A
/// touch is a new version (the app reads the text then, and finds it the same); a file next to it changing says nothing.
/// Two clients watching it share one watch.
@Test func aWatchedFilesVersionIsPushedAsItChangesAndGoes() async throws {
    let (d, c, root) = try daemon(); defer { d.stop() }
    let dir = tmp().path, path = dir + "/a.txt"
    try "one".write(toFile: path, atomically: true, encoding: .utf8)
    let heard = Heard(); heard.listen(c)
    let other = try client(root), hearsToo = Heard(); hearsToo.listen(other)
    c.notify(WatchStart(.file, path)); other.notify(WatchStart(.file, path))
    func stamps() -> [FileStamp?] { heard.events(FileEvent.self).map(\.stamp) }
    let first = try await c.call(FilesRead(path: path)).stamp
    #expect(try await waitFor(10) { stamps() == [first] && hearsToo.events(FileEvent.self).map(\.stamp) == [first] })
    #expect(d.watches.running == 1)
    try "two".write(toFile: path, atomically: true, encoding: .utf8)
    let second = try await c.call(FilesRead(path: path)).stamp
    #expect(try await waitFor(10) { stamps() == [first, second] })
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: path)
    #expect(try await waitFor(10) { stamps().count == 3 && stamps().last != second })
    try "b".write(toFile: dir + "/b.txt", atomically: true, encoding: .utf8)   // its neighbour
    try await Task.sleep(for: .milliseconds(1200))
    #expect(stamps().count == 3)
    try FileManager.default.removeItem(atPath: path)
    #expect(try await waitFor(10) { stamps().count == 4 && stamps().last == .some(nil) })
}

/// A workspace's files are pushed when the list changes, once; a file's text changing leaves the list as it was.
@Test func aWorkspacesFilesArePushedWhenTheListChanges() async throws {
    let w = try await world(); defer { w.d.stop() }
    let wt = try await firstDesk(w)
    let heard = Heard(); heard.listen(w.c)
    w.c.notify(WatchStart(.files, wt.id))
    let listed = try await w.c.call(FilesList(id: wt.id))
    #expect(try await waitFor(10) { heard.events(FilesEvent.self).map(\.paths) == [listed] })
    try "new\n".write(toFile: wt.path + "/added.txt", atomically: true, encoding: .utf8)
    #expect(try await waitFor(10) { heard.events(FilesEvent.self).last?.paths?.contains("added.txt") == true })
    try await Task.sleep(for: .milliseconds(1200))
    #expect(heard.events(FilesEvent.self).count == 2)   // once
    try "changed\n".write(toFile: wt.path + "/added.txt", atomically: true, encoding: .utf8)
    #expect(try await waitFor(10) { w.d.watches.reads.withLock { $0[Watches.Key(topic: .files, key: wt.id)] ?? 0 } >= 3 })   // read again…
    try await Task.sleep(for: .milliseconds(300))   // (counted before it's compared and pushed)
    #expect(heard.events(FilesEvent.self).count == 2)   // …not pushed
}

@Test func whatChangesAFileList() {
    #expect(Git.touchesFileList(["/r/src/a.swift"]) && Git.touchesFileList(["/r/.git/index"]) && Git.touchesFileList(["/r/.git/HEAD"]))
    #expect(!Git.touchesFileList(["/r/.git/objects/ab/cd", "/r/.git/logs/HEAD", "/r/.git"]))
}

/// Once the daemon stopped following folders, a project written after that (a late request) doesn't start watching
/// its .git again: it did, from the store's change hook on whatever thread wrote.
@Test func aProjectWrittenAfterStopIsntWatched() async throws {
    let (d, c, _) = try daemon(); defer { d.stop() }
    d.workspaces.stopWatching()
    _ = try await c.call("repo.add", .obj(["path": .string(try makeRepo())]))
    d.workspaces.headQueue.sync {}
    #expect(d.workspaces.heads.withLock { $0 ?? [:] }.isEmpty)
}

/// An agent's Bash commands, as its hooks tell them: in its list, pushed to whoever watches it; the one running on its
/// row; one whose end never came, stopped when its turn ends.
@Test func anAgentsCommandsAreListedAndTheRunningOneIsOnItsRow() async throws {
    let w = try await world(); defer { w.d.stop() }
    let wt = try await firstDesk(w)
    let s: Session = try await w.c.call("session.create", .obj(["worktreeId": .string(wt.id), "command": "sleep 30"]), as: Session.self)
    let heard = Heard(); heard.listen(w.c)
    w.c.notify(WatchStart(.commands, s.id))
    func hook(_ c: AgentCommand) async throws { _ = try await w.c.call(SessionHook(id: s.id, event: "command", command: c)) }
    func row() async throws -> Session? { try await w.c.call("session.list", as: [Session].self).first { $0.id == s.id } }
    func pushed() -> [AgentCommand]? { heard.events(CommandsEvent.self).last?.commands }
    try await hook(AgentCommand(id: "a", command: "swift test"))
    #expect(try await waitFor(10) { try await row()?.running == "swift test" })
    #expect(try await waitFor(10) { pushed()?.map(\.id) == ["a"] })
    try await hook(AgentCommand(id: "a", command: "swift test", started: Date(), ended: Date(), outcome: .failed, exitCode: 1, output: "1 failed"))
    #expect(try await waitFor(10) { try await row()?.running == nil })
    try await hook(AgentCommand(id: "b", command: "rm -rf build"))   // its permission denied: no end comes
    #expect(try await waitFor(10) { try await row()?.running == "rm -rf build" })
    _ = try await w.c.call("session.hook", .obj(["id": .string(s.id), "event": "done"]))
    #expect(try await waitFor(10) { pushed()?.map(\.outcome) == [.failed, .stopped] })
    #expect(try await row()?.running == nil)
    let list = try await w.c.call(SessionCommands(id: s.id))
    #expect(list.first?.exitCode == 1 && list.first?.output == "1 failed")
}
