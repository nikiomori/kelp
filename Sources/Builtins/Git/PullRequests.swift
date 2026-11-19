import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WorkbenchKit

/// A branch's pull request as Git marks it: "#12" beside its folder and on the window bar (`FolderCI.pr`), the PR in
/// full in the folder's hover card, and Create Pull Request where the branch has none.
enum PullRequests {
    /// "#12" in the PR's state colour, and the tooltip that says what it is. The PR's checks show as the folder's CI
    /// mark, and the tooltip counts them. Returns nil while Settings › Appearance › Changes and pull requests is off.
    /// A click opens the PR's own tab.
    @MainActor static func mark(_ folder: String, _ app: AppModel) -> (
        title: NSAttributedString, tip: String, uri: String
    )? {
        guard app.settings[SettingKeys.gitBadges], let pr = app.latest(PREvent.self, folder)?.pr else { return nil }
        let (title, tip) = badge(pr)
        return (title, tip, uri(folder, number: pr.number, page: pr.url, app))
    }

    /// The PR's own tab (Issues'), as the Issues panel opens it, or the PR's page while the folder's project isn't
    /// known.
    @MainActor static func uri(_ folder: String, number: Int?, page: String, _ app: AppModel) -> String {
        guard let repo = app.worktree(folder)?.repoId, let number else { return page }
        return TabURI.pullRequest(repo: repo, number: number)
    }

    @MainActor static func badge(_ pr: GitHub.PullRequest) -> (NSAttributedString, String) {
        let number = pr.number, state = pr.isDraft ? "DRAFT" : pr.state
        let color = NSColor.pullRequest(state: pr.state, draft: pr.isDraft)
        let failed = pr.checks.failed, pending = pr.checks.pending, passed = pr.checks.passed
        let label = NSAttributedString(
            string: "#\(number)",
            attributes: [.font: NSFont.uiDigits(TextSize.caption, weight: .medium), .foregroundColor: color])
        let checks =
            failed > 0
            ? String(localized: "\(failed) checks failing")
            : pending > 0
                ? String(localized: "\(pending) checks running")
                : passed > 0 ? String(localized: "checks passed") : String(localized: "no checks")
        let said =
            switch state {
            case "DRAFT": String(localized: "draft")
            case "MERGED": String(localized: "merged")
            case "CLOSED": String(localized: "closed")
            default: String(localized: "open")
            }
        return (label, String(localized: "Pull request #\(number) · \(said) · \(checks)") + "\n" + pr.title)
    }

    /// The PR as the folder's hover card shows it.
    @MainActor static func card(_ folder: String, _ app: AppModel) -> AnyView? {
        app.latest(PREvent.self, folder)?.pr.map { AnyView(PRLine(pr: $0)) }
    }

    /// Adds Create Pull Request to the branch chip's menu while the branch has no PR.
    @MainActor static func menuItems(_ menu: NSMenu, worktree: String?, _ app: AppModel) {
        guard let worktree, app.latest(PREvent.self, app.gitFolder(of: worktree)?.id ?? "")?.pr == nil else { return }
        menu.add(String(localized: "Create Pull Request…")) { PRActions(app).create(worktree: worktree) }
    }
}

/// "#123 Fix login · Open · checks passed": a PR in GitHub's own colours (open green, draft grey, merged purple,
/// closed red).
struct PRLine: View {
    let pr: GitHub.PullRequest
    var body: some View {
        let state =
            switch pr.isDraft ? "DRAFT" : pr.state {
            case "DRAFT": String(localized: "Draft")
            case "MERGED": String(localized: "Merged")
            case "CLOSED": String(localized: "Closed")
            default: String(localized: "Open (state)", defaultValue: "Open")
            }
        let color = Color(nsColor: .pullRequest(state: pr.state, draft: pr.isDraft))
        let failed = pr.checks.failed, pending = pr.checks.pending, passed = pr.checks.passed
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                SymbolIcon(
                    pr.state == "MERGED" ? "arrow.triangle.merge" : "arrow.triangle.pull", size: Metrics.iconSmall
                )
                .foregroundStyle(color)
                Text("#\(pr.number)").font(.ui(TextSize.row).monospacedDigit())
                Text(pr.title).font(.ui(TextSize.row)).lineLimit(1)
            }
            HStack(spacing: Metrics.gap) {
                Text(state).foregroundStyle(color)
                // Only a failure has a colour: running checks go by themselves (the agents' ring, grey) and passed ones
                // are a quiet filled ✓, as the sidebar's CI mark draws them.
                if failed > 0 {
                    SymbolIcon("xmark.circle.fill", size: Metrics.iconSmall).foregroundStyle(Color(nsColor: .systemRed))
                    Text("\(failed) failing").foregroundStyle(Color.textRed)
                } else if pending > 0 {
                    StatusIcon(status: .working)
                    Text("\(pending) running").foregroundStyle(.secondary)
                } else if passed > 0 {
                    SymbolIcon("checkmark.circle.fill", size: Metrics.iconSmall).foregroundStyle(.secondary)
                    Text("checks passed").foregroundStyle(.secondary)
                }
            }.font(.ui(TextSize.caption))
        }
    }
}

@MainActor
struct PRActions {
    let app: AppModel
    init(_ app: AppModel) { self.app = app }

    /// Pushes the branch and opens a PR whose title and body come from the branch's commits.
    func create(worktree wid: String) {
        let detail = String(
            localized: "Pushes \(app.worktree(wid)?.branch ?? "the branch") and opens a PR titled from its commits.")
        Task {
            guard
                await confirm(
                    String(localized: "Create a pull request?"), detail: detail, action: String(localized: "Create"))
            else { return }
            guard let url = await app.call(GitHubPRCreate(worktreeId: wid))?.url else { return }
            Banner.show(
                url.isEmpty
                    ? String(localized: "Pull request created") : String(localized: "Pull request created: \(url)"))
            if let link = URL(string: url), !url.isEmpty {   // ".../pull/12"
                let number = Int(link.lastPathComponent)
                app.workbench.open(PullRequests.uri(wid, number: number, page: link.absoluteString, app))
            }
        }
    }
}
