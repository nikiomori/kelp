import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

/// A branch's pull request as Git marks it: "#12" beside its folder and on the window bar (`FolderCI.pr`), in full in
/// the folder's hover card, and Create Pull Request where the branch has none.
enum PullRequests {
    /// "#12" in the PR's state colour, and what it says; its checks are the folder's CI mark, the tooltip counts them.
    /// Nothing while Settings › Appearance › Changes and pull requests is off.
    @MainActor static func mark(_ folder: String, _ app: AppModel) -> (
        title: NSAttributedString, tip: String, url: String
    )? {
        guard app.settings[SettingKeys.gitBadges], let pr = app.latest(PREvent.self, folder)?.pr else { return nil }
        let (title, tip) = badge(pr)
        return (title, tip, pr.url)
    }

    @MainActor static func badge(_ pr: GitHub.PullRequest) -> (NSAttributedString, String) {
        let number = pr.number, state = pr.isDraft ? "DRAFT" : pr.state
        let color: NSColor =
            state == "DRAFT"
            ? .secondaryLabelColor : state == "MERGED" ? .textPurple : state == "CLOSED" ? .textRed : .textGreen
        let failed = pr.checks.failed, pending = pr.checks.pending, passed = pr.checks.passed
        let label = NSAttributedString(
            string: "#\(number)", attributes: [.font: NSFont.uiDigits(11, weight: .medium), .foregroundColor: color])
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

    /// In the folder's hover card.
    @MainActor static func card(_ folder: String, _ app: AppModel) -> AnyView? {
        app.latest(PREvent.self, folder)?.pr.map { AnyView(PRLine(pr: $0)) }
    }

    /// The branch chip's menu: Create Pull Request while the branch has none.
    @MainActor static func menuItems(_ menu: NSMenu, worktree: String?, _ app: AppModel) {
        guard let worktree, app.latest(PREvent.self, app.gitFolder(of: worktree)?.id ?? "")?.pr == nil else { return }
        menu.add(String(localized: "Create Pull Request…")) { PRActions(app).create(worktree: worktree) }
    }
}

/// "#123 Fix login · Open · ✓ 5 checks": a PR in GitHub's own colours (open green, draft grey, merged purple,
/// closed red).
struct PRLine: View {
    let pr: GitHub.PullRequest
    var body: some View {
        let state = pr.isDraft ? String(localized: "Draft") : pr.state.capitalized
        let color: Color =
            state == String(localized: "Draft")
            ? .secondary : state == "Merged" ? .textPurple : state == "Closed" ? .textRed : .textGreen
        let failed = pr.checks.failed, pending = pr.checks.pending, passed = pr.checks.passed
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: state == "Merged" ? "arrow.triangle.merge" : "arrow.triangle.pull").foregroundStyle(
                    color)
                Text("#\(pr.number)").font(.ui(12).monospacedDigit())
                Text(pr.title).font(.ui(12)).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(state).foregroundStyle(color)
                if failed > 0 {
                    Text("✕ \(failed) failing").foregroundStyle(Color.textRed)
                } else if pending > 0 {
                    Text("● \(pending) running").foregroundStyle(Color.textOrange)
                } else if passed > 0 {
                    Text("✓ checks passed").foregroundStyle(Color.textGreen)
                }
            }.font(.ui(11))
        }
    }
}

@MainActor
struct PRActions {
    let app: AppModel
    init(_ app: AppModel) { self.app = app }

    /// Pushes and opens a PR; title and body come from the branch's commits.
    func create(worktree wid: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Create a pull request?")
        alert.informativeText = String(
            localized: "Pushes \(app.worktree(wid)?.branch ?? "the branch") and opens a PR titled from its commits.")
        alert.addButton(withTitle: String(localized: "Create"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        Task {
            guard await runSheet(alert) == .alertFirstButtonReturn else { return }
            guard let url = await app.call(GitHubPRCreate(worktreeId: wid))?.url else { return }
            Banner.show(
                url.isEmpty
                    ? String(localized: "Pull request created") : String(localized: "Pull request created: \(url)"))
            if let link = URL(string: url), !url.isEmpty { app.workbench.open(link.absoluteString) }
        }
    }
}
