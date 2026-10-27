import AppKit
import Foundation
import Testing
import Core
import GitKit
import Daemon
@testable import KelpApp
@testable import KelpKit
@testable import BuiltinAgents
@testable import BuiltinFiles
@testable import BuiltinGit
@testable import BuiltinBrowser
@testable import BuiltinIssues
@testable import BuiltinActivity

@MainActor private func buttons(in v: NSView) -> [NSButton] { ((v as? NSButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons) }
@MainActor private func tables(in v: NSView) -> [NSTableView] { ((v as? NSTableView).map { [$0] } ?? []) + v.subviews.flatMap(tables) }
/// Every cell of every table, made as a window on screen would (offscreen, tables make none until asked).
@MainActor private func cells(in v: NSView) -> [NSView] {
    tables(in: v).flatMap { t in (0..<t.numberOfRows).flatMap { r in (0..<t.numberOfColumns).compactMap { t.view(atColumn: $0, row: r, makeIfNecessary: true) } } }
}

/// The diff of one file as the user sees it, against a real daemon and repository: its Stage buttons stage that hunk
/// and only that one.
extension AppOfItsOwn {
    @Test func aHunksStageButtonStagesThatHunk() async throws {
        let lines = (1...40).map { "line \($0)" }
        let rig = try await AppRig(files: ["f.txt": lines.joined(separator: "\n") + "\n"]); defer { rig.done() }
        var changed = lines; changed[2] = "top change"; changed[35] = "bottom change"   // two hunks, far apart
        try rig.write("f.txt", changed.joined(separator: "\n") + "\n")
        let wt = rig.workspace, repo = rig.repo
        let vc = DiffViewController(app: rig.app)
        rig.show(vc, 900, 700)
        vc.showFile("f.txt", source: "unstaged", commit: nil)
        vc.show(worktree: wt.id)
        await vc.load()
        vc.view.layoutSubtreeIfNeeded()
        func stageButtons() -> [NSButton] { cells(in: vc.view).flatMap(buttons).filter { $0.action.map(NSStringFromSelector) == "hunkAction:" } }
        for _ in 0..<50 where stageButtons().count < 2 { try await Task.sleep(for: .milliseconds(50)); vc.view.layoutSubtreeIfNeeded() }
        let stage = stageButtons()
        try #require(stage.count == 2, "\(stage.count) stage buttons")
        stage[1].performClick(nil)   // the second hunk: "bottom change"
        var cached = ""
        for _ in 0..<100 where cached.isEmpty { try await Task.sleep(for: .milliseconds(50)); cached = try Git.run(["diff", "--cached"], cwd: repo) }
        #expect(cached.contains("+bottom change") && !cached.contains("+top change"))
    }
}

/// A folder Files can't list (moved away under Kelp, git refusing it) says why where the tree would be: it used to be
/// an empty tree, the same as an empty folder.
extension AppOfItsOwn {
    @Test func theFilesPanelSaysWhyItShowsNoFiles() async throws {
        let rig = try await AppRig(files: [:]); defer { rig.done() }
        try FileManager.default.removeItem(atPath: rig.repo)   // moved away: nothing can list it now
        let panel = FilesPanel(app: rig.app)
        rig.show(panel, 300, 500)
        await withCheckedContinuation { k in panel.reloadTree { k.resume() } }
        @MainActor func labels(_ v: NSView) -> [NSTextField] { ((v as? NSTextField).map { [$0] } ?? []) + v.subviews.flatMap(labels) }
        let said = labels(panel.view).filter { !$0.isHidden && $0.stringValue.contains("Couldn't list the files") }
        #expect(said.count == 1, "\(labels(panel.view).map(\.stringValue))")
    }
}

/// The review reads its diff once at a time: a burst of git events makes one more read, not one each; and an event
/// that moves nothing the diff is read from (a fetch changing ahead/behind) reads nothing.
extension AppOfItsOwn {
    @Test func gitEventsReadTheReviewOnceAtATimeAndOnlyWhenItsBasisMoved() async throws {
        let rig = try await AppRig(); defer { rig.done() }
        try rig.write("f.txt", "b\n")
        let wid = rig.workspace.id, vc = DiffViewController(app: rig.app)
        defer { rig.app.git[wid] = nil }
        rig.show(vc, 900, 700)
        let head = BranchInfo(current: "main", head: "abc1234", local: ["main"], remote: [], upstream: "origin/main", ahead: 0, behind: 0, merging: false)
        let e = GitEvent(worktree: wid, changes: [FileChange(path: "f.txt", index: ".", worktree: "M")], branches: head,
                         stats: LineStats(added: [.code: 1], removed: [.code: 1]))
        rig.app.git[wid] = e
        vc.show(worktree: wid)
        await vc.load()
        var reads = vc.reads
        for _ in 0..<10 { vc.reload() }
        await vc.load()
        #expect((1...2).contains(vc.reads - reads), "\(vc.reads - reads) reads")   // eleven asked: one read, or one more after it

        reads = vc.reads
        var fetched = e; fetched.branches?.behind = 3
        rig.app.git[wid] = fetched; vc.gitChanged(fetched)
        try await Task.sleep(for: .milliseconds(300))
        #expect(vc.reads == reads)
        var edited = fetched; edited.stats = LineStats(added: [.code: 2], removed: [.code: 1])
        rig.app.git[wid] = edited; vc.gitChanged(edited)
        for _ in 0..<250 where vc.reads == reads { try await Task.sleep(for: .milliseconds(20)) }   // a busy runner took over 300 ms
        #expect(vc.reads == reads + 1)
    }

    /// A file past one file's share of a review is listed, says it's too large, and opens on its own.
    @Test func aFileTooLargeForTheReviewOffersItsOwnTab() async throws {
        let lock = (0..<40_000).map { "\"package-\($0)\": \"1.0.\($0)\"" }   // regenerated: its diff is ~2.4 MB
        let rig = try await AppRig(files: ["f.txt": "a\n", "big.lock": lock.joined(separator: "\n") + "\n"]); defer { rig.done() }
        try rig.write("big.lock", lock.map { $0 + "-2" }.joined(separator: "\n") + "\n")
        try rig.write("f.txt", "b\n")
        let vc = DiffViewController(app: rig.app)
        rig.show(vc, 900, 700)
        vc.show(worktree: rig.workspace.id)
        await vc.load()
        #expect(vc.diffs.map(\.path).sorted() == ["big.lock", "f.txt"])
        #expect(vc.diffs.first { $0.path == "big.lock" }?.tooLarge == true)
        vc.view.layoutSubtreeIfNeeded()
        let open = cells(in: vc.view).flatMap(buttons).filter { $0.title == "Open Changes" }
        #expect(open.count == 1)
    }
}
