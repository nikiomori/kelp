// The task list's right-click menu and what it hands an agent: a task to start, an issue or review as a prompt.
import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

extension TasksViewController {
    /// The default agent starts on the issue in the workspace on screen, its text typed in but not sent: whoever filed the
    /// issue wrote it, so the user reads it before the agent acts on it.
    func startTask(ref: String, title: String, body: String, url: String) {
        guard let starter = app.workbench.starter, let wid = app.workbench.workspaceId else {
            NSSound.beep()
            return
        }
        Task {
            let issue = ["ref": ref, "title": title, "body": body, "url": url]
            guard let brief = await Self.issuePrompt(issue, in: wid, app) else { return }
            starter.newAgent(nil, prompt: brief, draft: true)
        }
    }

    /// The project's `issue` recipe, as `kelp github issue` writes it: the title and body framed as someone else's words.
    static func issuePrompt(_ issue: [String: String], in wid: String, _ app: AppModel) async -> String? {
        await app.call(RecipeRender(id: wid, name: "issue", vars: issue))
    }

    /// Review comments as the agent reads them: 12 at most, each cut at 800 characters, so a long thread stays a prompt.
    static func forAgent(_ cs: [GitHub.ReviewComment]) -> String {
        var parts: [String] = []
        for (index, comment) in cs.prefix(12).enumerated() {
            let line: String = comment.line.map { ":\($0)" } ?? ""
            let loc: String = comment.path.map { $0 + line } ?? String(localized: "General")
            let body = comment.body.count > 800 ? comment.body.prefix(800) + "…" : comment.body
            parts.append("\(index + 1). \(loc) (\(comment.author)):\n   \(body)")
        }
        if cs.count > 12 { parts.append("(\(cs.count - 12) more comments omitted.)") }
        return parts.joined(separator: "\n\n")
    }

    // MARK: right-click
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let row = row(at: table.clickedRow), let repoId else { return }
        switch row {
        case .pr(let pr):
            let work = PRWork(app: app, repoId: repoId, pr: pr)
            menu.add(String(localized: "Open in New Tab")) { [app] in
                app.workbench.open(ForgeItemTab.uri(.pr, repoId: repoId, number: pr.number))
            }
            menu.add(
                work.worktree == nil
                    ? String(localized: "Open in Its Own Folder") : String(localized: "Open Its Folder")
            ) {
                work.openFolder()
            }
            menu.add(String(localized: "Review with Agent")) {
                work.review(base: self.app.repo(repoId)?.baseBranch ?? "main")
            }
        case .issue(let issue):
            menu.add(String(localized: "Open in New Tab")) { [app] in
                app.workbench.open(ForgeItemTab.uri(.issue, repoId: repoId, number: issue.number))
            }
            menu.add(String(localized: "Start on Own Branch")) { [app] in
                IssueWork(app: app, repoId: repoId).startOnBranch(issue)
            }
            menu.add(String(localized: "Start Here")) { [app] in IssueWork(app: app, repoId: repoId).startHere(issue) }
        case .linear, .jira, .item:
            if let brief = Self.brief(row) {
                menu.add(String(localized: "Start Agent on This")) { [weak self] in
                    self?.startTask(ref: brief.ref, title: brief.title, body: brief.body, url: brief.url)
                }
            }
        }
        guard let url = row.url else { return }
        menu.addItem(.separator())
        menu.add(String(localized: "Open in Browser")) { Forge.open(url) }
        menu.add(String(localized: "Copy Link")) { copyText(url) }
    }
    /// What an agent starts from, for a tracker's task.
    private static func brief(_ row: Row) -> (ref: String, title: String, body: String, url: String)? {
        switch row {
        case .linear(let issue): (issue.identifier, issue.title, issue.description ?? "", issue.url)
        case .jira(let issue): (issue.key, issue.title, issue.description, issue.url)
        case .pr, .issue, .item: nil
        }
    }
}
