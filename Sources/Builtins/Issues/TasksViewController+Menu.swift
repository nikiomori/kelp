// The task list's right-click menu and what it hands an agent: a task to start, an issue or review as a prompt.
import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

extension TasksViewController {
    /// Review comments as the agent reads them: 12 at most, each cut at 800 characters, so a long thread stays a
    /// prompt.
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
        case .task(let task): return fillTaskMenu(menu, task)
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
            addTaskItem(menu, title: issue.title, url: issue.url)
        case .linear, .jira, .item:
            if let brief = Self.brief(row) {
                menu.add(String(localized: "Start Agent on This")) { [app] in IssueWork.startHere(app, brief) }
                if let title = brief["title"], let url = brief["url"] { addTaskItem(menu, title: title, url: url) }
            }
        }
        guard let url = row.url else { return }
        menu.addItem(.separator())
        menu.add(String(localized: "Open in Browser")) { Forge.open(url) }
        menu.add(String(localized: "Copy Link")) { copyText(url) }
    }
    /// What an agent starts from, for a tracker's task: the `issue` recipe's words.
    static func brief(_ row: Row) -> [String: String]? {
        switch row {
        case .linear(let issue):
            ["ref": issue.identifier, "title": issue.title, "body": issue.description ?? "", "url": issue.url]
        case .jira(let issue): ["ref": issue.key, "title": issue.title, "body": issue.description, "url": issue.url]
        case .pr, .issue, .item, .task: nil
        }
    }
}
