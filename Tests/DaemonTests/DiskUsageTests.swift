import AgentData
import Core
import Foundation
import GitKit
import Testing

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
