import AppKit
import Core
import KelpKit

/// A folder left on a branch whose PR merged, where the next agent would start on finished work. Kelp says so once,
/// as it happens (a PR already merged when Kelp opened is no news), and at the top of the project's menu for as long
/// as it stays so.
@MainActor
struct MergedPR {
    /// What can be done now. All of a project's workspaces share the folder, so any agent at work in it holds back the
    /// switch.
    enum Next: Equatable {
        case switchTo(String), agentWorking, uncommitted(Int)
    }

    /// The PRs that went from open to merged between two readings.
    nonisolated static func justMerged(_ now: [String: GitHub.PullRequest], was: [String: GitHub.PullRequest])
        -> [String: GitHub.PullRequest]
    {
        now.filter { id, p in p.state == "MERGED" && was[id]?.number == p.number && was[id]?.state == "OPEN" }
    }

    nonisolated static func next(base: String, working: Bool, uncommitted: Int) -> Next {
        working ? .agentWorking : uncommitted > 0 ? .uncommitted(uncommitted) : .switchTo(base)
    }

    let app: AppModel

    /// Nil unless the folder of `worktree` still stands on a merged PR's branch and isn't on the base branch already.
    func next(_ worktree: Worktree) -> (pr: GitHub.PullRequest, next: Next)? {
        guard let pr = app.latest(PREvent.self, worktree.id)?.pr, pr.state == "MERGED",
            pr.headRefName == worktree.branch,
            let base = app.repo(worktree.repoId)?.baseBranch,
            base != worktree.branch
        else { return nil }
        let working = app.sessions.contains {
            $0.status == .working && app.worktree($0.worktreeId)?.path == worktree.path
        }
        return (
            pr,
            Self.next(
                base: base, working: working, uncommitted: app.latest(GitEvent.self, worktree.id)?.changes?.count ?? 0)
        )
    }

    func tell(_ worktree: Worktree) {
        guard let (pr, next) = next(worktree) else { return }
        let title = String(localized: "PR #\(pr.number) merged")
        switch next {
        case .switchTo(let base):
            Banner.show(
                String(localized: "The project folder is still on \(worktree.branch)."),
                action: (String(localized: "Switch to \(base)"), { start(worktree, base) }), title: title)
        case .agentWorking:
            Banner.show(
                String(
                    localized:
                        "An agent is at work in the folder, so it stays on \(worktree.branch). The project’s menu can switch it later."
                ), title: title)
        case .uncommitted(let count):
            Banner.show(
                String(
                    localized:
                        "\(count) files not committed on \(worktree.branch). The project’s menu can switch it later."),
                title: title)
        }
    }

    /// Adds the switch at the top of the project's menu, enabled or disabled with the reason.
    func addItems(to menu: NSMenu, _ worktree: Worktree) {
        guard let (_, next) = next(worktree) else { return }
        let base = app.repo(worktree.repoId)?.baseBranch ?? ""
        let item = menu.add(String(localized: "Switch to \(base) and Pull")) { [self] in start(worktree, base) }
        if next != .switchTo(base) { item.action = nil }   // the menu greys out an item with nothing to do
        if case .uncommitted(let count) = next { item.toolTip = String(localized: "\(count) files not committed") }
        if next == .agentWorking { item.toolTip = String(localized: "An agent is at work in this folder") }
        menu.addItem(.separator())
    }

    /// Checks again as it starts, because a banner can wait a while. A failed step says why, and the folder stays where
    /// it was. The old branch stays too, because deleting it is another decision.
    private func start(_ worktree: Worktree, _ base: String) {
        guard next(worktree)?.next == .switchTo(base) else {
            tell(worktree)
            return
        }
        Task { [app] in
            guard await app.call(GitSwitch(id: worktree.id, branch: base)) != nil else { return }
            if let error = await GitSync.run(app, worktree.id, [.pull]) {
                Banner.show(error, style: .error)
            }
        }
    }
}
