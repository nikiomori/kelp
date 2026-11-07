import AppKit
import Foundation
import Testing
import TestSupport
import Core
import GitKit
import Daemon
import DesignKit
@testable import KelpApp
@testable import KelpKit
@testable import BuiltinAgents
@testable import BuiltinFiles
@testable import BuiltinGit
@testable import BuiltinBrowser
@testable import BuiltinIssues
@testable import BuiltinActivity

/// Source Control as the user sees it: the real controller, a real daemon and a real git repository, in a window that's
/// never shown. Rows are read back out of its outline.
@MainActor private func texts(_ v: NSView) -> [String] {
    var out: [String] = []
    if let t = v as? NSTextField, !t.stringValue.isEmpty, !t.isHidden { out.append(t.stringValue) }
    for s in v.subviews where !s.isHidden { out += texts(s) }
    return out
}
@MainActor private func outlines(in v: NSView) -> [NSOutlineView] {
    (v as? NSOutlineView).map { [$0] } ?? v.subviews.flatMap(outlines)
}

extension AppOfItsOwn {
@Test func sourceControlListsStagedAndChangedFilesFromTheDaemon() async throws {
    let rig = try await AppRig(files: ["kept.txt": "a\n"]); defer { rig.done() }
    try rig.write("kept.txt", "b\n")                                                          // changed, not staged
    try rig.write("staged.txt", "new\n"); try rig.git("add", "staged.txt")
    let vc = SourceControlController(app: rig.app)
    rig.show(vc, 320, 700)
    vc.view.layoutSubtreeIfNeeded()
    #expect(vc.worktreeId == rig.workspace.id)   // it follows the workspace on screen by itself
    vc.followWatches()                           // now that it is in a window: watches the workspace, the daemon pushes its git
    let outline = try #require(outlines(in: vc.view).first)
    func rows() -> [String] { (0..<outline.numberOfRows).flatMap { (outline.view(atColumn: 0, row: $0, makeIfNecessary: true)).map(texts) ?? [] } }
    #expect(try await waitFor(5) { rows().contains("staged.txt") })
    let shown = rows()
    #expect(shown.contains("staged.txt") && shown.contains("kept.txt"), "\(shown)")
    #expect(shown.contains { $0.localizedCaseInsensitiveContains("Staged") })   // its section header
    let staged = try #require(shown.firstIndex(of: "staged.txt")), changed = try #require(shown.firstIndex(of: "kept.txt"))
    #expect(staged < changed)   // staged first, then the rest, as VS Code lists them
}

/// Each workspace has its own commit message and its own running action: a switch leaves them where they were, and what
/// ends in another workspace doesn't land on the one on screen.
@Test func sourceControlKeepsEachWorkspacesWork() async throws {
    let rig = try await AppRig(files: ["kept.txt": "a\n"]); defer { rig.done() }
    let vc = SourceControlController(app: rig.app), here = rig.workspace.id
    rig.show(vc, 320, 700)
    vc.message.string = "half a message"
    vc.begin(here, syncing: ("Pushing…", true, false))
    vc.bind("another")
    #expect(vc.message.string.isEmpty && !vc.busy && vc.syncing == nil)
    vc.end(here, syncing: true)
    #expect(!vc.busy)
    vc.bind(here)
    #expect(vc.message.string == "half a message" && !vc.busy)
}

/// Staging while a push runs: the push still shows, and a second one isn't started.
@Test func sourceControlActionsDontEndEachOther() async throws {
    let rig = try await AppRig(files: ["kept.txt": "a\n"]); defer { rig.done() }
    let vc = SourceControlController(app: rig.app), here = rig.workspace.id
    rig.show(vc, 320, 700)
    vc.begin(here, syncing: ("Pushing…", true, false))
    vc.begin(here)
    vc.end(here, syncing: false)
    #expect(vc.busy && vc.syncing?.title == "Pushing…")
    vc.run { GitRemoteOp(id: $0, op: "push") }
    #expect(vc.work[here]?.running == 1)
    vc.end(here, syncing: true)
    #expect(!vc.busy && vc.syncing == nil)
}

/// The button's glow follows its capsule wherever the button sits: it used to be moved off by the button's own place.
@Test func theCommitButtonsGlowStaysOnIt() throws {
    let b = SplitPushButton(title: "Commit", arrowTip: ""), host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    host.addSubview(b)
    b.frame = NSRect(x: 60, y: 40, width: 120, height: 28)
    b.layout()
    let glow = try #require(b.subviews.first { $0 is EdgeGlow })
    #expect(abs(glow.frame.midX - b.bounds.midX) < 4 && abs(glow.frame.midY - b.bounds.midY) < 4, "\(glow.frame)")
}

/// With nothing staged a commit takes everything, but not on the word of a status list cut at its limit.
@Test func aCommitDoesntTakeEverythingFromACutList() {
    let one = FileChange(path: "a", index: ".", worktree: "M")
    #expect(GitCommit.takesEverything([one]))
    #expect(!GitCommit.takesEverything(Array(repeating: one, count: FileChange.limit)))
    #expect(!GitCommit.takesEverything([one, FileChange(path: "b", index: "M", worktree: ".")]))
}

/// A commit that went in with a push that didn't: not a push that worked.
@Test func aFailedPushIsntReportedAsPushed() async throws {
    let rig = try await AppRig(files: ["kept.txt": "a\n"]); defer { rig.done() }
    rig.show(SourceControlController(app: rig.app), 320, 700)   // the failure's banner needs a window
    try rig.write("kept.txt", "b\n")   // no remote to push to
    let r = await GitCommit.run(rig.app, rig.workspace.id, message: "m", push: true, amend: false)
    #expect(r.committed && !r.pushed)
}

/// A few changes take their rows' height and the graph follows right under them, not half the panel down.
@Test func theGraphFollowsAShortListOfChanges() async throws {
    UserDefaults.standard.removeObject(forKey: "scm.graphHeight"); UserDefaults.standard.removeObject(forKey: "scm.collapsed")
    let rig = try await AppRig(files: ["kept.txt": "a\n"]); defer { rig.done() }
    try rig.write("kept.txt", "b\n")
    let vc = SourceControlController(app: rig.app)
    rig.show(vc, 320, 800)
    vc.followWatches()
    let outline = try #require(outlines(in: vc.view).first), graph = try #require(outlines(in: vc.view).last)
    #expect(try await waitFor(5) { !(outline.numberOfRows < 2 || graph.numberOfRows < 1) })
    vc.view.window?.setContentSize(NSSize(width: 320, height: 800))   // the window took the panel's fitting size
    vc.view.layoutSubtreeIfNeeded()
    let changes = try #require(outline.enclosingScrollView), rows = outline.rect(ofRow: outline.numberOfRows - 1).maxY
    #expect(abs(changes.frame.height - rows) < 1, "\(changes.frame.height) for \(rows) of rows")
    let below = try #require(graph.enclosingScrollView).frame
    #expect(below.height > vc.view.bounds.height / 2, "\(below) in \(vc.view.bounds), changes \(changes.frame)")   // the room left
}

/// A narrow inspector truncates what doesn't fit (the commit message's hint with the branch in it) instead of clipping
/// the panel's right edge: the commit button's menu, the counts, the graph's labels.
@Test func sourceControlFitsANarrowInspector() async throws {
    let rig = try await AppRig(files: ["kept.txt": "a\n"]); defer { rig.done() }
    try rig.write("kept.txt", "b\n")
    let vc = SourceControlController(app: rig.app)
    rig.show(vc, 260, 700)
    vc.followWatches()
    #expect(try await waitFor(5) { texts(vc.view).contains(where: { $0.hasPrefix("Message") }) })
    vc.view.layoutSubtreeIfNeeded()
    #expect(vc.view.fittingSize.width <= 260, "\(vc.view.fittingSize.width)")
}
}

/// A commit's branches and tags lead its line in the graph: the first (HEAD's branch first), then how many more, their
/// names in that badge's tooltip.
@MainActor @Test func aCommitsLineLeadsWithItsFirstBranchAndHowManyMore() {
    let v = CommitCell.badges(["origin/feat", "tag: v1", "HEAD -> main"])
    #expect(v.count == 2 && v[0].toolTip == "main" && v[1].toolTip == "origin/feat\nv1")
    #expect(CommitCell.badges([]).isEmpty && CommitCell.badges(["tag: v1"]).count == 1)
}
