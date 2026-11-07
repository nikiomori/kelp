import AppKit
import Core
import KelpKit

extension TasksViewController {
    /// Merge, in any of GitHub's three ways, as a menu: the commit on screen is the one that lands (`--match-head-commit`).
    func mergeButton(_ r: GitHub.PullRequest, _ wt: Worktree?) -> NSView {
        let pop = NSPopUpButton(frame: .zero, pullsDown: true)
        pop.addItem(withTitle: String(localized: "Merge"))
        pop.item(at: 0)?.image = .symbol("arrow.triangle.merge")
        for (title, method) in [
            (String(localized: "Squash and Merge"), "squash"), (String(localized: "Create a Merge Commit"), "merge"),
            (String(localized: "Rebase and Merge"), "rebase")
        ] {
            pop.menu?.add(title) { [weak self] in self?.merge(r.number, r.headRefOid, wt, method: method, title: title)
            }
        }
        return pop
    }

    private func merge(_ n: Int, _ head: String?, _ wt: Worktree?, method: String, title: String) {
        let a = NSAlert()
        a.messageText = String(localized: "\(title) #\(n)?")
        a.addButton(withTitle: String(localized: "Merge"))
        a.addButton(withTitle: String(localized: "Cancel"))
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn else { return }
            // The merge runs in a workspace of the project (gh needs a checkout); the PR's own if it has one.
            guard let wid = wt?.id ?? app.worktrees.first(where: { $0.repoId == repoId })?.id else {
                NSSound.beep()
                return
            }
            if await app.call(GitHubPRMerge(worktreeId: wid, pr: n, method: method, head: head)) != nil {
                status.stringValue = String(localized: "Merged #\(n)")
                reload()
            }
        }
    }

    /// Why GitHub won't merge it yet, in words; nil when nothing stands in the way (or GitHub hasn't said).
    static func mergeBlock(_ r: GitHub.PullRequest) -> String? {
        switch r.mergeState {
        case "DIRTY": String(localized: "It conflicts with the base branch: resolve the conflicts first.")
        case "BEHIND": String(localized: "The base branch moved on: update this branch first.")
        case "DRAFT": String(localized: "It's a draft: mark it ready for review first.")
        case "UNSTABLE": String(localized: "Some checks failed, though GitHub lets it merge.")
        case "BLOCKED": blocked(r)
        default: nil
        }
    }

    /// GitHub says only BLOCKED: the review or the checks, when they are what it waits for.
    private static func blocked(_ r: GitHub.PullRequest) -> String {
        if r.reviewDecision == "CHANGES_REQUESTED" { return String(localized: "A reviewer asked for changes.") }
        if r.reviewDecision == "REVIEW_REQUIRED" { return String(localized: "It needs an approving review.") }
        if r.checks.failed > 0 { return String(localized: "Required checks failed.") }
        if r.checks.pending > 0 { return String(localized: "Required checks are still running.") }
        return String(localized: "The repository's rules block it.")
    }
}
