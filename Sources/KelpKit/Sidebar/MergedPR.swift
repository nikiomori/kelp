import AppKit
import Core

/// A folder left on a branch whose PR merged: the next agent would start on finished work. Said once, as it happens (one
/// already merged when Kelp opened is no news), and at the top of the project's menu for as long as it's so.
@MainActor
struct MergedPR {
    /// What can be done now. All of a project's workspaces share the folder, so any agent at work in it holds the switch.
    enum Next: Equatable {
        case switchTo(String), agentWorking, uncommitted(Int)
    }

    /// The PRs that went from open to merged between two readings.
    nonisolated static func justMerged(_ now: [String: GitHub.PullRequest], was: [String: GitHub.PullRequest]) -> [String: GitHub.PullRequest] {
        now.filter { id, p in p.state == "MERGED" && was[id]?.number == p.number && was[id]?.state == "OPEN" }
    }

    nonisolated static func next(base: String, working: Bool, uncommitted: Int) -> Next {
        working ? .agentWorking : uncommitted > 0 ? .uncommitted(uncommitted) : .switchTo(base)
    }

    let app: AppModel

    /// Nil unless `w`'s folder still stands on a merged PR's branch and isn't on the base branch already.
    func next(_ w: Worktree) -> (pr: GitHub.PullRequest, next: Next)? {
        guard let p = app.rowBadges.prs[w.id], p.state == "MERGED", p.headRefName == w.branch, let base = app.repo(w.repoId)?.baseBranch,
              base != w.branch else { return nil }
        let working = app.sessions.contains { $0.status == .working && app.worktree($0.worktreeId)?.path == w.path }
        return (p, Self.next(base: base, working: working, uncommitted: app.git[w.id]?.changes?.count ?? 0))
    }

    func tell(_ w: Worktree) {
        guard let (pr, next) = next(w) else { return }
        let title = String(localized: "PR #\(pr.number) merged")
        switch next {
        case .switchTo(let base):
            Banner.show(String(localized: "The project folder is still on \(w.branch)."),
                        action: (String(localized: "Switch to \(base)"), { start(w, base) }), title: title)
        case .agentWorking:
            Banner.show(String(localized: "An agent is at work in the folder, so it stays on \(w.branch). The project's menu can switch it later."), title: title)
        case .uncommitted(let n):
            Banner.show(String(localized: "\(n) files not committed on \(w.branch). The project's menu can switch it later."), title: title)
        }
    }

    /// At the top of the project's menu: on, or off saying why.
    func addItems(to m: NSMenu, _ w: Worktree) {
        guard let (_, next) = next(w) else { return }
        let base = app.repo(w.repoId)?.baseBranch ?? ""
        let item = m.add(String(localized: "Switch to \(base) and Pull")) { [self] in start(w, base) }
        if next != .switchTo(base) { item.action = nil }   // the menu greys an item with nothing to do
        if case .uncommitted(let n) = next { item.toolTip = String(localized: "\(n) files not committed") }
        if next == .agentWorking { item.toolTip = String(localized: "An agent is at work in this folder") }
        m.addItem(.separator())
    }

    /// Asked again as it starts: a banner can wait a while. A failed step says why, the folder stays where it was. The old
    /// branch stays too: deleting it is another decision.
    private func start(_ w: Worktree, _ base: String) {
        guard next(w)?.next == .switchTo(base) else { tell(w); return }
        Task { [app] in
            guard await app.call(GitSwitch(id: w.id, branch: base)) != nil else { return }
            if let e = await GitSync.run(app, w.id, ["pull"]) { Banner.show(e, style: .error) }
        }
    }
}
