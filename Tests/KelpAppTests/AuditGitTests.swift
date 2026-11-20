import AppKit
import Core
import DesignKit
import Testing

@testable import BuiltinGit
@testable import BuiltinIssues
@testable import KelpApp
@testable import KelpKit

/// Every text colour a view's labels draw in, its own and its subviews'.
@MainActor private func textColors(_ view: NSView) -> [NSColor] {
    var found: [NSColor] = []
    if let field = view as? NSTextField {
        let text = field.attributedStringValue
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let color = value as? NSColor { found.append(color) }
        }
    }
    return found + view.subviews.flatMap(textColors)
}

/// Every label's text in a view.
@MainActor private func texts(_ view: NSView) -> [String] {
    ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts)
}

@MainActor private func pullRequest(_ checks: GitHub.PullRequest.Checks) -> GitHub.PullRequest {
    GitHub.PullRequest(
        number: 1, title: "T", url: "", author: "a", headRefName: "b", isDraft: false, state: "OPEN", checks: checks)
}

/// A pull request's row says its checks in colour only when they fail: passed checks are a grey ✓, not green.
@MainActor @Test func aPullRequestsChecksHaveAColourOnlyWhenTheyFail() {
    let rows: [(checks: GitHub.PullRequest.Checks, red: Bool)] = [
        (.init(passed: 3), false), (.init(pending: 1), false), (.init(passed: 2, failed: 1), true)
    ]
    for row in rows {
        let said = textColors(ForgeRows.pr(pullRequest(row.checks), worktree: false, unseen: false))
        #expect(!said.contains { $0 === NSColor.textGreen }, "\(row.checks)")
        #expect(said.contains { $0 === NSColor.textRed } == row.red, "\(row.checks)")
    }
}

/// A tag in the history graph is grey: orange is for what waits for you.
@MainActor @Test func aTagInTheHistoryIsGrey() {
    let labels = CommitCell.labels(["HEAD -> main", "tag: v1.0"])
    #expect(labels.first { $0.0 == "v1.0" }?.1 == NSColor.secondaryLabelColor)
}

/// A review comment's row says a sent or resolved state in words, and draws no emoji or bracketed raw value.
@MainActor @Test func aReviewCommentSaysItsStateInWords() {
    let vc = DiffViewController(app: AppModel(builtins: Builtins.all))
    _ = vc.view
    let rows: [(state: DiffComment.State, word: String?)] = [(.open, nil), (.sent, "sent"), (.resolved, "resolved")]
    for row in rows {
        var comment = DiffComment(worktreeId: "w", file: "f.txt", startLine: 1, endLine: 1, quote: "", text: "why?")
        comment.state = row.state
        #expect(DiffViewController.stateWord(row.state) == row.word)
        let said = texts(vc.commentRow(comment))
        #expect(!said.contains { $0.contains("💬") || $0.contains("[") }, "\(row.state)")
        #expect(said.contains("why?"))
    }
}

/// Each of GitHub's three ways to merge asks before it merges, so its menu item ends in "…". (The question is a sheet,
/// which a test can't answer: only the mark is checked.)
@MainActor @Test func theWaysToMergeEndInAnEllipsis() {
    let menu = PRWork(app: AppModel(builtins: []), repoId: "r", pr: pullRequest(.init())).mergeMenu {}
    #expect(menu.items.count == 3)
    #expect(menu.items.allSatisfy { $0.title.hasSuffix("…") })
}

/// A diff with no files says "No Changes" where the diff stands, and one git couldn't read says why there, with Try
/// Again; the bar counts files only when there are some ("0 files +0 −0" said nothing).
@MainActor @Test func anEmptyOrFailedDiffSaysSoWhereTheDiffStands() {
    let vc = DiffViewController(app: AppModel(builtins: Builtins.all))
    _ = vc.view
    vc.showState(error: "fatal: not a git repository")
    #expect(vc.empty.showing && vc.status.stringValue.isEmpty)
    vc.showState(error: nil)
    #expect(vc.empty.showing && vc.status.stringValue.isEmpty)
    vc.diffs = [FileDiff(path: "f.swift", header: "", hunks: [], binary: false)]
    vc.showState(error: nil)
    #expect(!vc.empty.showing && !vc.status.stringValue.isEmpty)
}

/// A commit's menu, as right-click and the card's ⋯ show it: open, share, change the branch, copy, in that order, with
/// the keys Return and ⌘C. Cherry-Pick names the current branch and is left out for a commit the branch already has.
@MainActor
@Test(arguments: [
    (
        "side",
        "Open Changes ↩|Open in Browser|Send to Agent|-|Check Out…|Create Branch Here…|Cherry-Pick into main…|"
            + "Revert…|-|Copy Hash ⌘c|Copy Message"
    ),
    (
        "base",
        "Open Changes ↩|Open in Browser|Send to Agent|-|Check Out…|Create Branch Here…|Revert…|-|Copy Hash ⌘c|"
            + "Copy Message"
    )
])
func aCommitsMenuListsItsActionsInOrder(commit: String, items: String) throws {
    let vc = SourceControlController(app: AppModel(builtins: Builtins.all))
    func c(_ hash: String, _ parents: [String]) -> GraphCommit {
        GraphCommit(
            hash: hash, parents: parents, author: "", date: 0, subject: hash, refs: [], lane: 0, top: [], bottom: [])
    }
    vc.commits = [c("head", ["base"]), c("side", ["base"]), c("base", [])]
    vc.info = BranchInfo(current: "main", head: "head", local: ["main"], remote: [], merging: false)
    let menu = NSMenu()
    vc.addCommitItems(try #require(vc.commits.first { $0.hash == commit }), to: menu)
    let shown = menu.items.map { item in
        guard !item.isSeparatorItem else { return "-" }
        let key = item.keyEquivalent == "\r" ? "↩" : item.keyEquivalent.isEmpty ? "" : "⌘" + item.keyEquivalent
        return key.isEmpty ? item.title : item.title + " " + key
    }
    #expect(shown.joined(separator: "|") == items)
}
