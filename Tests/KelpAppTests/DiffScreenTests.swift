import AppKit
import Foundation
import Testing
import Core
import GitKit
import Daemon
import WorkbenchKit
import DesignKit
@testable import KelpApp
@testable import KelpKit
@testable import BuiltinAgents
@testable import BuiltinFiles
@testable import BuiltinGit
@testable import BuiltinBrowser
@testable import BuiltinIssues
@testable import BuiltinActivity

@MainActor private func buttons(in v: NSView) -> [NSButton] { ((v as? NSButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons) }
/// The line a diff row shows, inline or side by side (the new side's when it has both).
private func shown(_ r: ReviewRow) -> DiffLine? {
    switch r {
    case .diff(.line(_, let l)): l
    case .diff(.pair(_, let l, let r)): r ?? l
    default: nil
    }
}
@MainActor private func tables(in v: NSView) -> [NSTableView] { ((v as? NSTableView).map { [$0] } ?? []) + v.subviews.flatMap(tables) }
/// Every cell of every table, made as a window on screen would (offscreen, tables make none until asked).
@MainActor private func cells(in v: NSView) -> [NSView] {
    tables(in: v).flatMap { t in (0..<t.numberOfRows).flatMap { r in (0..<t.numberOfColumns).compactMap { t.view(atColumn: $0, row: r, makeIfNecessary: true) } } }
}

/// The diff of one file as the user sees it, against a real daemon and repository: its Stage buttons stage that hunk
/// and only that one.
extension AppOfItsOwn {
    /// A line fixed in the diff goes into the file as shown; one an agent changed since is left alone.
    @Test func aLineFixedInTheDiffIsWrittenOnlyOverWhatWasShown() async throws {
        let rig = try await AppRig(files: ["f.txt": "one\ntwo\n"]); defer { rig.done() }
        try rig.write("f.txt", "one\ntpyo\n")
        let vc = DiffViewController(app: rig.app)
        rig.show(vc, 900, 700)
        vc.showFile("f.txt", source: "unstaged", commit: nil)
        vc.show(worktree: rig.workspace.id)
        await vc.load()
        await vc.write("typo", over: "tpyo", path: "f.txt", line: 2)
        #expect(try String(contentsOfFile: rig.repo + "/f.txt", encoding: .utf8) == "one\ntypo\n")
        await vc.write("again", over: "tpyo", path: "f.txt", line: 2)
        #expect(try String(contentsOfFile: rig.repo + "/f.txt", encoding: .utf8) == "one\ntypo\n")
    }

    /// ⌘F finds lines across the diff and steps through them round; ⌥↓ says which change of how many it is on.
    @Test func aDiffIsSearchedAndSteppedThrough() async throws {
        let lines = (1...40).map { "line \($0)" }
        let rig = try await AppRig(files: ["f.txt": lines.joined(separator: "\n") + "\n"]); defer { rig.done() }
        var changed = lines; changed[2] = "top Change"; changed[35] = "bottom change"
        try rig.write("f.txt", changed.joined(separator: "\n") + "\n")
        let vc = DiffViewController(app: rig.app)
        rig.show(vc, 900, 700)
        vc.showFile("f.txt", source: "unstaged", commit: nil)
        vc.show(worktree: rig.workspace.id)
        await vc.load()
        await vc.search("CHANGE").value   // any case, looked for off the main thread
        #expect(vc.find.rows.count == 2 && vc.find.at == 0 && vc.table.selectedRow == vc.find.rows[0])
        vc.stepFind(next: true); vc.stepFind(next: true)
        #expect(vc.find.at == 0)   // round to the first
        vc.stepFind(next: false)
        #expect(vc.find.at == 1)
        vc.table.deselectAll(nil)
        vc.nextChange(); vc.nextChange()
        #expect(vc.position.stringValue == "Change 2 of 2")
        await vc.search("").value
        #expect(vc.find.rows.isEmpty)
    }

    /// A file's Viewed box marks it read and counts what's left; the mark is kept in the daemon's state for the workspace.
    @Test func aFileMarkedViewedCountsAsRead() async throws {
        let rig = try await AppRig(files: ["a.txt": "a\n", "b.txt": "b\n"]); defer { rig.done() }
        try rig.write("a.txt", "a2\n"); try rig.write("b.txt", "b2\n")
        let vc = DiffViewController(app: rig.app)
        rig.show(vc, 900, 700)
        vc.show(worktree: rig.workspace.id)
        await vc.load()
        try #require(vc.diffs.count == 2)
        let box = vc.viewedBox(0)
        box.state = .on
        box.performClick(nil); box.performClick(nil)   // a click flips it: off, then on again
        #expect(vc.status.stringValue.contains("1 of 2 left"))
        for _ in 0..<250 where rig.app.uiState.strings(ViewedFiles.key(rig.workspace.id)).isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(rig.app.uiState.strings(ViewedFiles.key(rig.workspace.id)).count == 1)
    }

    /// The unchanged lines between two changes open in place with a click on their capsule.
    @Test func aGapBetweenChangesOpensInPlace() async throws {
        let lines = (1...40).map { "line \($0)" }
        let rig = try await AppRig(files: ["f.txt": lines.joined(separator: "\n") + "\n"]); defer { rig.done() }
        var changed = lines; changed[2] = "top"; changed[35] = "bottom"
        try rig.write("f.txt", changed.joined(separator: "\n") + "\n")
        let vc = DiffViewController(app: rig.app)
        rig.show(vc, 900, 700)
        vc.show(worktree: rig.workspace.id)
        await vc.load()
        guard case .diff(.gap(let f, let from, let n, _))? = vc.rows.first(where: { if case .diff(.gap) = $0 { true } else { false } }) else {
            Issue.record("no gap"); return
        }
        let button = try #require(vc.gapRow(file: f, from: from, lines: n, context: "").subviews.first as? NSButton)
        button.performClick(nil)
        for _ in 0..<100 where vc.rows.contains(where: { if case .diff(.gap) = $0 { true } else { false } }) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!vc.rows.contains { if case .diff(.gap) = $0 { true } else { false } })
        #expect(vc.rows.contains { shown($0)?.text == "line 20" && shown($0)?.kind == .context })
    }

    /// A selection across two files comments on the first file's lines only: its range never takes another file's numbers.
    @Test func aCommentStaysInOneFile() async throws {
        let rig = try await AppRig(files: ["a.txt": "1\n2\n3\n4\nfive\n", "b.txt": "one\n"]); defer { rig.done() }
        try rig.write("a.txt", "1\n2\n3\n4\nFIVE\n"); try rig.write("b.txt", "ONE\n")
        let vc = DiffViewController(app: rig.app)
        rig.show(vc, 900, 700)
        vc.show(worktree: rig.workspace.id)
        await vc.load()
        let a = try #require(vc.rows.firstIndex { shown($0)?.text == "FIVE" }), b = try #require(vc.rows.firstIndex { shown($0)?.text == "ONE" })
        vc.table.selectRowIndexes([a, b], byExtendingSelection: false)
        vc.openDraft()
        #expect(vc.draft?.file == "a.txt" && vc.draft?.start == 5 && vc.draft?.end == 5 && vc.draft?.quote == "FIVE")
    }

    /// A comment is written in a card under its line, which a new read of the diff keeps, and ⌘↩'s button saves.
    @Test func aCommentIsWrittenInACardUnderItsLine() async throws {
        let rig = try await AppRig(files: ["f.txt": "one\ntwo\n"]); defer { rig.done() }
        try rig.write("f.txt", "one\nTWO\n")
        let vc = DiffViewController(app: rig.app)
        rig.show(vc, 900, 700)
        vc.show(worktree: rig.workspace.id)
        await vc.load()
        let at = try #require(vc.rows.firstIndex { shown($0)?.text == "TWO" })
        vc.openDraft(at: at)
        #expect(vc.rows[at + 1] == .draft)
        vc.draft?.field.stringValue = "why upper case?"
        await vc.load()   // an agent's change read again: the card and its text stay under the line
        #expect(vc.rows[at + 1] == .draft && vc.draft?.field.stringValue == "why upper case?")
        let save = try #require(buttons(in: vc.draftCard()).first { $0.keyEquivalent == "\r" })
        save.performClick(nil)
        for _ in 0..<100 where !vc.rows.contains(where: { if case .comment = $0 { true } else { false } }) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(vc.draft == nil && !vc.rows.contains(.draft))
        let line = try #require(vc.rows.firstIndex { shown($0)?.text == "TWO" })   // read again: found again
        #expect(vc.rows[line + 1] == .comment(vc.comments[0]) && vc.comments[0].text == "why upper case?")
    }

    /// Findings are picked: Space on a selected comment leaves it out of Send to Agent, and its box says so.
    @Test func findingsArePickedBeforeTheyGo() async throws {
        let rig = try await AppRig(files: ["f.txt": "one\ntwo\n"]); defer { rig.done() }
        try rig.write("f.txt", "one\nTWO\n")
        _ = try await rig.client.call(CommentAdd(id: rig.workspace.id, file: "f.txt", start: 2, text: "first"))
        _ = try await rig.client.call(CommentAdd(id: rig.workspace.id, file: "f.txt", start: 2, text: "second"))
        let vc = DiffViewController(app: rig.app)
        rig.show(vc, 900, 700)
        vc.show(worktree: rig.workspace.id)
        await vc.load()
        #expect(vc.picked.count == 2)
        let at = try #require(vc.rows.firstIndex { if case .comment = $0 { true } else { false } })
        vc.table.selectRowIndexes([at], byExtendingSelection: false)
        #expect(vc.flipSelectedComment())
        #expect(vc.picked.count == 1)
        guard case .comment(let c) = vc.rows[at] else { return }
        let box = try #require(buttons(in: vc.commentRow(c)).first { $0.title.isEmpty })
        #expect(box.state == .off)
    }

    /// The reviewer is pointed at exactly what the diff shows: its source's own git command.
    @Test func aReviewCoversWhatTheDiffShows() async throws {
        let rig = try await AppRig(files: ["f.txt": "one\n"]); defer { rig.done() }
        try rig.write("f.txt", "two\n")
        let vc = DiffViewController(app: rig.app)
        rig.show(vc, 900, 700)
        vc.show(worktree: rig.workspace.id)
        await vc.load()
        #expect(vc.reviewScope(rig.workspace.id).1 == "git diff HEAD; git status --short")
        vc.source.selectItem(at: 2)
        #expect(vc.reviewScope(rig.workspace.id).1 == "git diff --cached")
        vc.source.selectItem(at: 3)
        #expect(vc.reviewScope(rig.workspace.id).1 == "git diff '\(rig.workspace.base)...HEAD'")
        let menu = try #require(vc.reviewPop.menu)
        vc.reviewItems(menu)
        #expect(menu.numberOfItems >= 2)   // the title, then the agents (or why there are none)
    }

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

/// A diff's menus offer what the row under the pointer can take: nothing on a plain line, one state on a comment, and
/// Stage or Unstage as the file stands.
extension AppOfItsOwn {
    @Test func aDiffsMenusOfferOnlyWhatTheRowCanTake() async throws {
        let rig = try await AppRig(files: ["f.txt": "one\n", "g.txt": "two\n"]); defer { rig.done() }
        try rig.write("f.txt", "changed\n")
        try rig.write("g.txt", "changed\n")
        let wt = rig.workspace
        _ = await rig.app.call(GitStage(id: wt.id, files: ["g.txt"]))
        _ = await rig.app.call(CommentAdd(id: wt.id, file: "f.txt", start: 1, end: 1, quote: "changed", text: "why"))
        let vc = DiffViewController(app: rig.app)
        rig.show(vc, 900, 700)
        vc.show(worktree: wt.id)
        await vc.load()

        func fileItems(_ path: String) throws -> [String] {
            let m = NSMenu()
            vc.fileMenu(m, row: try #require(vc.diffs.firstIndex { $0.path == path }))
            return m.items.map(\.title)
        }
        #expect(try fileItems("f.txt") == ["Stage", "", "Open File", "Copy Path"])
        #expect(try fileItems("g.txt") == ["Unstage", "", "Open File", "Copy Path"])
        vc.fileMenu(NSMenu(), row: -1)

        func lineItems(_ row: Int) -> [String] {
            let m = NSMenu()
            vc.lineMenu(m, row: row)
            return m.items.map(\.title)
        }
        let comment = try #require(vc.rows.firstIndex { if case .comment = $0 { true } else { false } })
        #expect(lineItems(comment) == ["Mark Resolved"])
        let plain = try #require(vc.rows.indices.first { $0 != comment })
        #expect(lineItems(plain).isEmpty)
        let line = try #require(vc.rows.firstIndex { if case .diff(.line) = $0 { true } else if case .diff(.pair) = $0 { true } else { false } })
        #expect(lineItems(line).contains("Add Comment…"))
    }
}

/// A minified line in a diff: the regexes were quadratic in it, a text field takes seconds over a megabyte.
@MainActor @Test func aVeryLongDiffLineIsCutAndLeftUncolored() {
    let long = "let a = 1; " + String(repeating: "x", count: Highlighter.maxColored)
    let font = NSFont.systemFont(ofSize: 12)
    func colored(_ s: String) -> Bool {
        var found = false
        Highlighter.attributed(s, ext: "js", font: font).enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: 3)) { c, _, _ in
            found = found || (c as? NSColor) != .labelColor
        }
        return found
    }
    #expect(colored("let a = 1;"))
    #expect(!colored(long))
    #expect(DiffViewController.shown("short") == "short")
    #expect(DiffViewController.shown(String(repeating: "y", count: 30_000)).utf16.count == 20_001)
}

/// A diff colours as the editor does: each side parsed whole, a capture cut at line ends, a removed line from the old side.
@MainActor @Test func aDiffIsColoredByTheEditorsGrammar() {
    let lines = [DiffLine(kind: .context, text: "let a = \"x\"", oldLine: 1, newLine: 1), DiffLine(kind: .del, text: "var b = 1", oldLine: 2),
                 DiffLine(kind: .add, text: "/* one", newLine: 2), DiffLine(kind: .add, text: "two */", newLine: 3)]
    let d = [FileDiff(path: "a.swift", header: "", hunks: [Hunk(header: "@@", oldStart: 1, newStart: 1, lines: lines)], binary: false)]
    let spans = DiffColors.spans(d, grammars: DiffColors.grammars(d))
    #expect(spans["0:n:1"]?.contains { $0.name == "string" && $0.range.location == 8 } == true)
    #expect(spans["0:o:2"]?.contains { $0.name.hasPrefix("keyword") && $0.range == NSRange(location: 0, length: 3) } == true)
    #expect(spans["0:n:2"]?.contains { $0.name == "comment" && $0.range == NSRange(location: 0, length: 6) } == true)
    #expect(spans["0:n:3"]?.contains { $0.name == "comment" && $0.range == NSRange(location: 0, length: 6) } == true)
    #expect(spans["0:o:1"] == nil)   // an unchanged line once, from the new side
    #expect(DiffColors.grammars([FileDiff(path: "notes.unknownext", header: "", hunks: d[0].hunks, binary: false)]).isEmpty)
}

/// A wrapped line goes on under its code, past the marker and the line's own indent (tabs every four columns).
@Test func aWrappedDiffLineKeepsItsIndent() {
    #expect(DiffViewController.indent("+ ", "    x") == 6)
    #expect(DiffViewController.indent("+ ", "\tx") == 4)
    #expect(DiffViewController.indent(" ", "\t\t x") == 9)
    #expect(DiffViewController.indent("- ", "x  ") == 2)
}

/// A tab's toolbar gives its push buttons, pop-ups and segments one size and font; Kelp's own buttons keep theirs.
@MainActor @Test func aContentBarsControlsAreOneSize() {
    let push = NSButton(title: "Comment", target: nil, action: nil), pop = NSPopUpButton(), seg = NSSegmentedControl()
    push.bezelStyle = .push
    let check = NSButton(checkboxWithTitle: "Viewed", target: nil, action: nil), own = PointerButton()
    let inner = NSPopUpButton()
    _ = Bar.content([pop, NSStackView(views: [inner]), push], [seg, check, own])
    #expect([push, pop, seg, inner].allSatisfy { $0.controlSize == .small && $0.font == .ui(11) })
    #expect(check.controlSize == .regular && own.controlSize == .regular)
}
