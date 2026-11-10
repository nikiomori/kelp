import AppKit
import Core
import Daemon
import Foundation
import GitKit
import TestSupport
import Testing

@testable import BuiltinActivity
@testable import BuiltinAgents
@testable import BuiltinBrowser
@testable import BuiltinFiles
@testable import BuiltinGit
@testable import BuiltinIssues
@testable import KelpApp
@testable import KelpKit

/// KelpApp code reads `Paths` (scratch, extensions, skills) and agents' folders: the process is isolated (TestIsolation).
let testHome: String = {
    _ = TestIsolation.root
    return String(cString: getenv("KELP_HOME"))
}()

/// Tests that touch what the process has once (UserDefaults, the extensions folder, a menu bar): one at a time.
@Suite(.serialized) @MainActor struct OneAtATime {}
/// Tests whose views are handed an app of their own (each `AppRig` makes one): they run alongside the rest.
@MainActor struct AppOfItsOwn {}

/// A daemon of the test's own in a short temp folder (its socket path must fit 104 bytes), a git repository with `files`
/// committed and added as its project, and an app of the test's own pointed at both. `done()` stops the daemon and
/// removes the folder.
@MainActor
final class AppRig {
    /// The app the views under test are given.
    let app: AppModel
    let root: URL, daemon: Daemon, client: RPCClient
    let repo: String, project: Repo, workspace: Worktree
    private var windows: [NSWindow] = []

    init(files: [String: String] = ["f.txt": "a\n"]) async throws {
        _ = testHome
        app = AppModel(builtins: Builtins.all)
        root = URL(fileURLWithPath: "/tmp/kr-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        daemon = try Daemon(root: root)
        try daemon.start()
        client = try RPCClient(socket: root.appendingPathComponent("kelp.sock").path)
        repo = root.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        for a in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]] {
            try Git.run(a, cwd: repo)
        }
        for (name, text) in files { try text.write(toFile: repo + "/" + name, atomically: true, encoding: .utf8) }
        if !files.isEmpty {
            try Git.run(["add", "."], cwd: repo)
            try Git.run(["commit", "-qm", "init"], cwd: repo)
        }
        project = try await client.call(RepoAdd(path: repo))
        guard let w = try await client.call(WorktreeList(repoId: project.id)).first else {
            throw RPCError.internalError("no workspace")
        }
        workspace = w
        let m = app, wb = app.workbench
        m.daemon.use(client)
        m.listen(client)
        m.repos = [project]
        m.worktrees = [workspace]
        wb.workspaceId = workspace.id
    }

    func write(_ name: String, _ text: String) throws {
        try text.write(toFile: repo + "/" + name, atomically: true, encoding: .utf8)
    }
    func git(_ args: String...) throws { try Git.run(args, cwd: repo) }

    /// `vc` in a window that's never shown, at that size, kept until `done()`.
    func show(_ vc: NSViewController, _ w: CGFloat, _ h: CGFloat) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentViewController = vc
        windows.append(window)
    }

    func done() {
        daemon.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

/// Until what the main actor was given before now has run (a task, and the one that task began): what a check that
/// nothing happened there reads after.
@MainActor func mainActorTurns() async { for _ in 0..<2 { await Task {}.value } }
