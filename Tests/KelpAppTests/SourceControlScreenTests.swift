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
    for _ in 0..<100 where !rows().contains("staged.txt") { try await Task.sleep(for: .milliseconds(50)) }
    let shown = rows()
    #expect(shown.contains("staged.txt") && shown.contains("kept.txt"), "\(shown)")
    #expect(shown.contains { $0.localizedCaseInsensitiveContains("Staged") })   // its section header
    let staged = try #require(shown.firstIndex(of: "staged.txt")), changed = try #require(shown.firstIndex(of: "kept.txt"))
    #expect(staged < changed)   // staged first, then the rest, as VS Code lists them
}

/// A narrow inspector truncates what doesn't fit (the commit message's hint with the branch in it) instead of clipping
/// the panel's right edge: the commit button's menu, the counts, the graph's labels.
@Test func sourceControlFitsANarrowInspector() async throws {
    let rig = try await AppRig(files: ["kept.txt": "a\n"]); defer { rig.done() }
    try rig.write("kept.txt", "b\n")
    let vc = SourceControlController(app: rig.app)
    rig.show(vc, 260, 700)
    vc.followWatches()
    for _ in 0..<100 where !texts(vc.view).contains(where: { $0.hasPrefix("Message") }) { try await Task.sleep(for: .milliseconds(50)) }
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
