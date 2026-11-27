import AgentData
import Core
import Foundation
import GitKit
import Testing
import os

@testable import Daemon

private func blob(_ path: String, mb: Int = 2) throws {
    try FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data(repeating: 1, count: mb << 20).write(to: URL(fileURLWithPath: path))
}

/// A build here and in an agent's worktree rebuilds; what else git ignores is the user's to judge; a folder holding a
/// worktree, a tracked file or one in an ignored folder git still tracks never goes to the Trash.
@Test func diskUsageSortsWhatRebuildsAndTrashesOnlyThat() async throws {
    let (d, c, _, repo) = try await world()
    defer { d.stop() }
    let root = DiskUsage.real(repo.path)
    try ".build/\ndist/\nlogs/\n.claude/\n/box/x/\n/box/y/\n".write(
        toFile: root + "/.git/info/exclude", atomically: true, encoding: .utf8)
    try blob(root + "/.build/debug/app")
    try blob(root + "/dist/Kelp.dmg")
    try blob(root + "/logs/old.log")
    try blob(root + "/box/x/a")
    try blob(root + "/box/y/a")
    try "keep\n".write(toFile: root + "/logs/keep.txt", atomically: true, encoding: .utf8)
    try Git.run(["add", "-f", "logs/keep.txt"], cwd: root, remotes: .none)
    try Git.run(["commit", "-qm", "keep"], cwd: root, remotes: .none)
    try Git.run(["worktree", "add", "-q", "-b", "agent", ".claude/worktrees/agent"], cwd: root, remotes: .none)
    let worktree = root + "/.claude/worktrees/agent"
    try blob(worktree + "/.build/debug/app", mb: 3)

    let items = try await c.call(RepoDiskUsage(id: repo.id))
    let by = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
    #expect(by[root + "/.build"]?.what == .build && by[root + "/.build"]?.removable == true)
    #expect(by[worktree + "/.build"]?.what == .build && by[worktree + "/.build"]?.worktree == worktree)
    #expect(by[root + "/dist"]?.what == .ignored)
    #expect(by[root + "/logs/old.log"]?.what == .ignored)   // its folder has a tracked file: listed file by file
    #expect(by[root + "/box"] == nil && by[root + "/box/x"]?.removable == true)   // git lists box/ as well
    #expect(by[root]?.what == .files && by[root]?.removable == false)
    #expect(by[root + "/.claude"] == nil)   // the worktree inside is its own; the rest is too small to list
    #expect(items.map(\.bytes) == items.map(\.bytes).sorted(by: >))

    let res = try await c.call(
        RepoDiskTrash(
            id: repo.id,
            paths: [
                root + "/.build", worktree + "/.build", root + "/dist", root + "/logs", root + "/.claude", root,
                root + "/a.txt", "/etc"
            ]))
    #expect(Set(res.removed) == [root + "/.build", worktree + "/.build", root + "/dist"])
    #expect(res.kept[root + "/logs"] == "Git tracks it.")
    #expect(res.kept[root + "/a.txt"] == "Git tracks it.")
    #expect(res.kept[root + "/.claude"] == "A worktree is inside it.")
    #expect(res.kept[root] == "Not part of the project." && res.kept["/etc"] == "Not part of the project.")
    #expect(!FileManager.default.fileExists(atPath: root + "/.build"))
    #expect(
        FileManager.default.fileExists(atPath: root + "/logs/old.log")
            && FileManager.default.fileExists(atPath: worktree))
}

/// Claude Code's chats for the project's folders and Xcode's DerivedData for it are found by the names those tools give.
@Test func diskUsageFindsChatsAndDerivedData() throws {
    let base = URL(fileURLWithPath: DiskUsage.real(tmp().path))
    let root = base.appendingPathComponent("my.app").path
    try Git.run(["init", "-q", root], cwd: base.path, remotes: .none)
    let chats = base.appendingPathComponent("projects"), derived = base.appendingPathComponent("DerivedData")
    try blob(chats.appendingPathComponent(DiskUsage.claudeName(root)).path + "/a.jsonl")
    try blob(chats.appendingPathComponent("-other").path + "/a.jsonl")
    let mine = derived.appendingPathComponent("App-abc"), theirs = derived.appendingPathComponent("Other-def")
    for (dir, workspace) in [(mine, root + "/App.xcodeproj"), (theirs, "/elsewhere/Other.xcodeproj")] {
        try blob(dir.path + "/Build/x")
        try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": workspace], format: .xml, options: 0)
            .write(to: dir.appendingPathComponent("info.plist"))
    }
    #expect(DiskUsage.claudeName("/Users/me/my.app") == "-Users-me-my-app")
    let items = try DiskUsage.measure(root: root, worktrees: [], remotes: .none, chats: chats, derived: derived)
    #expect(
        items.filter { $0.what == .chats }.map(\.path) == [
            chats.appendingPathComponent(DiskUsage.claudeName(root)).path
        ])
    #expect(items.filter { $0.what == .build }.map(\.path) == [mine.path])
}

/// A remote project's disk is measured on its host and named as its folder here names it; a build there goes into the
/// project's .git/kelp-trash on the host, a tracked file and a path out of the project stay.
@Test func aRemoteProjectsDiskIsMeasuredAndTrashedOnItsHost() async throws {
    _ = localSSH   // before the daemon: it reads KELP_SSH as it starts
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let (repo, _, there) = try await remoteProject(c)
    let real = DiskUsage.real(there)
    try ".build/\ndist/\n.claude/\n".write(toFile: real + "/.git/info/exclude", atomically: true, encoding: .utf8)
    try blob(real + "/.build/debug/app")
    try blob(real + "/dist/app.tar")
    try Git.run(["worktree", "add", "-q", "-b", "agent", ".claude/worktrees/agent"], cwd: real, remotes: .none)
    try blob(real + "/.claude/worktrees/agent/.build/x", mb: 3)

    let items = try await c.call(RepoDiskUsage(id: repo.id))
    let by = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
    let worktree = repo.path + "/.claude/worktrees/agent"
    #expect(by[repo.path + "/.build"]?.what == .build && by[repo.path + "/.build"]?.removable == true)
    #expect(by[worktree + "/.build"]?.worktree == worktree)
    #expect(by[repo.path + "/dist"]?.what == .ignored && by[repo.path]?.what == .files)

    let res = try await c.call(
        RepoDiskTrash(id: repo.id, paths: [repo.path + "/.build", repo.path + "/a.txt", repo.path + "/../x", "/etc"]))
    #expect(res.removed == [repo.path + "/.build"])
    #expect(res.kept[repo.path + "/a.txt"] == "Git tracks it." && res.kept["/etc"] == "Not part of the project.")
    #expect(res.kept[repo.path + "/../x"] == "Not part of the project.")
    #expect(!FileManager.default.fileExists(atPath: real + "/.build"))
    let bin = try FileManager.default.subpathsOfDirectory(atPath: real + "/.git/kelp-trash")
    #expect(bin.contains { $0.hasSuffix(".build/debug/app") })
}

/// On a host, a build in a worktree beside the project's folder is the one that goes. Its path there is as long as the
/// main checkout's: with that length dropped unchecked, the main checkout's build went in its place.
@Test func aHostsWorktreeBuildGoesNotTheMainCheckouts() async throws {
    _ = localSSH
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let (repo, _, there) = try await remoteProject(c)
    let real = DiskUsage.real(there), beside = DiskUsage.real(tmp().path)
    try #require(real.count == beside.count)
    try ".build/\n".write(toFile: real + "/.git/info/exclude", atomically: true, encoding: .utf8)
    try Git.run(["worktree", "add", "-q", "-b", "feat", beside], cwd: real, remotes: .none)
    try blob(real + "/.build/app")
    try blob(beside + "/.build/app")

    let items = try await c.call(RepoDiskUsage(id: repo.id))
    let build = try #require(items.first { $0.worktree == beside })   // named as the host names it
    #expect(build.path == beside + "/.build" && build.removable)
    let res = try await c.call(RepoDiskTrash(id: repo.id, paths: [build.path]))
    #expect(res.removed == [build.path] && res.kept.isEmpty, "\(res)")
    #expect(!FileManager.default.fileExists(atPath: beside + "/.build"), "the worktree's build is still there")
    #expect(FileManager.default.fileExists(atPath: real + "/.build/app"), "the main checkout's build went")
}

/// A remote project's file is named on its host by its path as it reads with `..` taken out, and only when it's in
/// the project's folder: any other path's rest names another file there.
@Test func aHostsNameIsOnlyForAPathInTheProject() async throws {
    let files = HostFiles(folder: "/k/remote/box/app-2", remote: RemoteHost(host: "box", path: "/srv/app"))
    #expect(try files.there("/k/remote/box/app-2/src/a.txt") == "/srv/app/src/a.txt")
    #expect(try files.there("/k/remote/box/app-2") == "/srv/app")
    #expect(try files.there("/k/remote/box/app-2/../app-2/x") == "/srv/app/x")   // not app-2 beside it on the host
    await expectRefusal(says: "isn't in the project") { try files.there("/k/remote/box/other/x") }   // as long as the folder
}

/// A worktree's own folder never goes aside on a host as an ignored folder: in `.claude/` git ignores it and tracks
/// nothing in it, and it would go whole, uncommitted work and all.
@Test func aWorktreesOwnFolderIsNeverTrashedOnAHost() async throws {
    _ = localSSH
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let (repo, _, there) = try await remoteProject(c)
    let real = DiskUsage.real(there), beside = DiskUsage.real(tmp().path)
    try ".claude/\n".write(toFile: real + "/.git/info/exclude", atomically: true, encoding: .utf8)
    try Git.run(["worktree", "add", "-q", "-b", "agent", ".claude/worktrees/agent"], cwd: real, remotes: .none)
    try Git.run(["worktree", "add", "-q", "-b", "feat", beside], cwd: real, remotes: .none)
    try "work\n".write(toFile: real + "/.claude/worktrees/agent/new.txt", atomically: true, encoding: .utf8)

    let own = repo.path + "/.claude/worktrees/agent"
    let res = try await c.call(RepoDiskTrash(id: repo.id, paths: [own, own + "/", beside, repo.path + "/.claude"]))
    #expect(res.removed.isEmpty, "\(res)")
    #expect(res.kept[own] == "It is a worktree." && res.kept[own + "/"] == "It is a worktree.")
    #expect(res.kept[beside] == "Not part of the project.")
    #expect(res.kept[repo.path + "/.claude"] == "A worktree is inside it.")
    #expect(FileManager.default.fileExists(atPath: real + "/.claude/worktrees/agent/new.txt"))
}

/// Nor here, spelled other than git prints it (through `..`, a link, with a slash after it): as git prints it, it goes
/// as a worktree does, kept while it holds work.
@Test func aWorktreesOwnFolderIsNeverTrashedHere() async throws {
    let (d, c, _, repo) = try await world()
    defer { d.stop() }
    let root = DiskUsage.real(repo.path), worktree = root + "/.claude/worktrees/agent"
    try ".claude/\n".write(toFile: root + "/.git/info/exclude", atomically: true, encoding: .utf8)
    try Git.run(["worktree", "add", "-q", "-b", "agent", ".claude/worktrees/agent"], cwd: root, remotes: .none)
    try "work\n".write(toFile: worktree + "/new.txt", atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: root + "/.claude/link", withDestinationPath: worktree)

    let spelled = [root + "/.claude/worktrees/../worktrees/agent", root + "/.claude/link", worktree + "/"]
    let res = try await c.call(RepoDiskTrash(id: repo.id, paths: spelled + [worktree]))
    #expect(res.removed.isEmpty, "\(res)")
    #expect(spelled.allSatisfy { res.kept[$0] == "It is a worktree." } && res.kept[worktree] != nil, "\(res)")
    #expect(FileManager.default.fileExists(atPath: worktree + "/new.txt"))
}

/// A `du` that failed is an error naming what it was measuring, never 0 bytes: here when it can't run, on a host when
/// it's killed there. One that only couldn't read something (1) still counts the rest.
@Test func aFailedDuIsNeverANumber() throws {
    let folder = DiskUsage.real(tmp().path)
    try blob(folder + "/a")
    #expect(try RepoWorktreeSizes.du(folder) >= 2 << 20)
    #expect(throws: RPCError.self) { try Subprocess.quickOnly { try RepoWorktreeSizes.du(folder) } }
    // A host of its own: its `ssh` runs the command here, with a `du` that ends as it's told first in PATH.
    let bin = tmp()
    func script(_ name: String, _ text: String) throws {
        try ("#!/bin/sh\n" + text + "\n").write(to: bin.appendingPathComponent(name), atomically: true, encoding: .utf8)
        chmod(bin.appendingPathComponent(name).path, 0o755)
    }
    try script("ssh", "for last; do :; done\nPATH=\"\(bin.path):$PATH\" exec /bin/sh -c \"$last\"")
    var host = RemoteHost(host: "box", path: folder)
    host.ssh = bin.appendingPathComponent("ssh").path
    try script("du", "/usr/bin/du \"$@\"; exit 1")
    #expect(try DiskUsage.du([folder], on: host)[folder] ?? 0 >= 2 << 20)
    try script("du", "/usr/bin/du \"$@\"; exit 137")
    #expect {
        try DiskUsage.du([folder], on: host)
    } throws: { error in
        (error as? RPCError)?.message.hasPrefix("\(folder) wasn't measured: ") == true
    }
}

/// Two asks for a project's worktrees' sizes at once run one sweep and share it, and one a moment later is given it
/// again (every hover card of the project asks); a Disk Usage measure sweeps anew, and so does anyone once worktrees
/// were removed.
@Test func worktreeSizesAreSweptOnceAtATime() async throws {
    let (d, c, _, repo) = try await world()
    defer { d.stop() }
    let runs = OSAllocatedUnfairLock(initialState: 0), sweeps = d.workspaces.sweeps
    let sweep: @Sendable () -> [RepoWorktreeSizes.Item] = {
        // The first runs long enough for the second ask to come while it does.
        if runs.withLock({ $0 += 1; return $0 == 1 }) { Thread.sleep(forTimeInterval: 0.2) }
        return []
    }
    DispatchQueue.concurrentPerform(iterations: 2) { _ in _ = sweeps.sizes(of: "p", sweep) }
    #expect(runs.withLock { $0 } == 1)
    _ = sweeps.sizes(of: "p", again: true, sweep)
    _ = sweeps.sizes(of: "q", sweep)   // another project's own
    #expect(runs.withLock { $0 } == 3)

    // Through the daemon, by what it finds: a file added since isn't counted until someone measures.
    let root = DiskUsage.real(repo.path), worktree = root + "/.claude/worktrees/"
    for name in ["work", "clean"] {
        try Git.run(["worktree", "add", "-q", "-b", name, ".claude/worktrees/" + name], cwd: root, remotes: .none)
    }
    try blob(worktree + "work/a")
    let first = try await c.call(RepoWorktreeSizes(id: repo.id))
    try blob(worktree + "work/b", mb: 3)
    #expect(try await c.call(RepoWorktreeSizes(id: repo.id)) == first)
    let measured = try await c.call(RepoDiskUsage(id: repo.id)).first { $0.path == worktree + "work" }
    #expect((measured?.bytes ?? 0) >= 5 << 20)
    #expect(try await c.call(RepoWorktreeSizes(id: repo.id)).first?.bytes ?? 0 >= 5 << 20)   // and left its answer
    let res = try await c.call(RepoRemoveWorktrees(id: repo.id, paths: [worktree + "clean"]))
    #expect(res.removed == [worktree + "clean"], "\(res)")
    #expect(try await c.call(RepoWorktreeSizes(id: repo.id)).map(\.path) == [worktree + "work"])
}

/// A real host, read only (KELP_TEST_REMOTE=host:/path of a project there): GNU du and git there answer as on this Mac,
/// the parts add up to the folder, and nothing is moved.
@Test(.enabled(if: ProcessInfo.processInfo.environment["KELP_TEST_REMOTE"] != nil))
func aRealHostsProjectIsMeasuredThere() async throws {
    let target = (ProcessInfo.processInfo.environment["KELP_TEST_REMOTE"] ?? "").split(separator: ":", maxSplits: 1)
        .map(String.init)
    try #require(target.count == 2)
    let w = try await world()
    defer { w.d.stop() }
    let repo = try await w.c.call(RepoAddRemote(host: target[0], path: target[1]))
    let started = Date()
    let items = try await w.c.call(RepoDiskUsage(id: repo.id))
    for item in items { print("HOST", item.what, item.bytes >> 20, "MB", item.path, item.removable) }
    print("HOST took", Date().timeIntervalSince(started))
    let files = try #require(items.first { $0.what == .files })
    #expect(files.path == repo.path && items.allSatisfy { $0.bytes >= 0 })
}
