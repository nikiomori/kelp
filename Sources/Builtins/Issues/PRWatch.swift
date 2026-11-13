import Core
import DesignKit
import Foundation
import KelpKit

extension PRsEvent: Pushed {
    package var key: String { repo }
    package static var forgottenWith: WatchTopic? { .prs }
}

/// What the pull requests ask of you while you're elsewhere: the open PRs of the project on screen, watched (the daemon
/// reads them every two minutes), how many wait for your review (the number on the panel's icon), and which changed
/// since you last opened them.
@MainActor @Observable
final class PRWatch {
    private let app: AppModel
    @ObservationIgnored private let watched: Watched
    /// Who gh is signed in as: whose review is asked for.
    private(set) var viewer: String?

    init(app: AppModel) {
        self.app = app
        watched = Watched(.prs, in: app)
        track(owner: self) { [app] in
            app.worktree(app.workbench.workspaceId)?.repoId
        } changed: { [weak self] in
            self?.watched.key = $0
        }
        Task { [weak self] in
            guard let self else { return }
            viewer = await Viewer.get(app)
        }
    }

    /// The project's open PRs as last read; nil until then, or when they couldn't be.
    func prs(_ repo: String?) -> [GitHub.PullRequest]? { app.latest(PRsEvent.self, repo ?? "")?.prs }

    var badge: PanelBadge? {
        guard let viewer, let prs = prs(app.worktree(app.workbench.workspaceId)?.repoId) else { return nil }
        let waiting = prs.filter { $0.reviewRequests?.contains(viewer) == true }.count
        return waiting > 0 ? PanelBadge("\(waiting)") : nil
    }

    // MARK: changed since you looked

    private static let key = "issues.seenPRs"
    /// A PR's page and when it last changed as you saw it. The first time the list shows a PR is as good as a look:
    /// only what changes after that is news.
    private static var seen: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue.count > 500 ? [:] : newValue, forKey: key) }
    }

    /// Takes note of the PRs not seen before; the numbers of those that changed since they were last opened.
    static func unseen(_ prs: [GitHub.PullRequest]) -> Set<Int> {
        var known = seen, news: Set<Int> = []
        for pr in prs {
            guard let updated = pr.updatedAt else { continue }
            if let last = known[pr.url] {
                if updated > last { news.insert(pr.number) }
            } else {
                known[pr.url] = updated
            }
        }
        if known.count != seen.count { seen = known }
        return news
    }

    /// Opened: what it says now is seen.
    static func saw(_ pr: GitHub.PullRequest) {
        guard let updated = pr.updatedAt else { return }
        seen[pr.url] = updated
    }
}
