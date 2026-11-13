import AppKit
import Core
import DesignKit
import KelpKit

/// The tab's bar: where it goes, the one thing to do next as the blue button, Files, and the rest under ⋯.
extension ForgeItemTab {
    func prBar() -> NSView {
        guard let view = prView else { return Bar.content([], [moreButton(issueMenu: false)]) }
        let pr = view.pr, work = PRWork(app: app, repoId: repoId, pr: pr)
        let route = NSTextField.label(
            "\(pr.headRefName) → \(view.baseRefName)", font: .ui(TextSize.row), color: .secondaryLabelColor,
            truncation: .byTruncatingMiddle)
        var trailing: [NSView] = []
        let refresh: () -> Void = { [weak self] in self?.reload() }
        switch PRWork.next(pr, mine: pr.author == viewer) {
        case .fix: trailing.append(primary(String(localized: "Fix with Agent")) { work.fixChecks() })
        case .answer:
            trailing.append(primary(String(localized: "Send Review Comments to Agent")) { work.answerReviews() })
        case .review:
            trailing.append(primary(String(localized: "Review with Agent")) { work.review(base: view.baseRefName) })
        case .merge:
            let merge = primary(String(localized: "Merge…")) {}
            merge.onClick = { [weak merge] in
                guard let merge else { return }
                work.mergeMenu(done: refresh).popUp(
                    positioning: nil, at: NSPoint(x: 0, y: merge.bounds.height + 4), in: merge)
            }
            trailing.append(merge)
        case .wait: break
        }
        let files = TextButton(String(localized: "Files")) { work.showFiles() }
        files.toolTip = String(localized: "Its changes against \(view.baseRefName), in its own folder")
        trailing += [files, moreButton(issueMenu: false)]
        return Bar.content([route], trailing, stretching: route)
    }

    func issueBar() -> NSView {
        guard let view = issueView else { return Bar.content([], [moreButton(issueMenu: true)]) }
        let issue = view.issue
        let route = NSTextField.label(
            issue.assignees.isEmpty
                ? String(localized: "Nobody assigned")
                : String(localized: "Assigned to \(issue.assignees.joined(separator: ", "))"),
            font: .ui(TextSize.row), color: .secondaryLabelColor)
        var trailing: [NSView] = []
        if let folder = issueFolder {
            trailing.append(
                primary(String(localized: "Open Its Group")) { [app] in app.workbench.show(workspace: folder.id) })
        } else if issue.state == "OPEN" {
            trailing.append(primary(String(localized: "Start on Own Branch")) { [weak self] in self?.startOnBranch() })
        }
        trailing.append(moreButton(issueMenu: true))
        return Bar.content([route], trailing, stretching: route)
    }

    /// The next thing to do: the accent's push button, the one blue thing in the bar.
    private func primary(_ title: String, _ action: @escaping () -> Void) -> PointerButton {
        let button = TextButton(title, onClick: action)
        button.restFill = .controlAccentColor
        button.contentTintColor = .white
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.ui(TextSize.row, weight: .medium), .foregroundColor: NSColor.white])
        return button
    }

    private func moreButton(issueMenu: Bool) -> NSView {
        let more = IconButton(.symbol("ellipsis"), tip: String(localized: "More")) {}
        more.onClick = { [weak self, weak more] in
            guard let self, let more else { return }
            let menu = issueMenu ? self.issueMoreMenu() : self.prMoreMenu()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more)
        }
        return more
    }

    private func prMoreMenu() -> NSMenu {
        let menu = NSMenu()
        if let view = prView {
            let pr = view.pr, work = PRWork(app: app, repoId: repoId, pr: pr)
            menu.add(
                work.worktree == nil
                    ? String(localized: "Open in Its Own Folder") : String(localized: "Open Its Folder")
            ) {
                work.openFolder()
            }
            menu.add(String(localized: "Review with Agent")) { work.review(base: view.baseRefName) }
            if pr.checks.failed > 0 { menu.add(String(localized: "Fix Checks with Agent")) { work.fixChecks() } }
            menu.add(String(localized: "Send Review Comments to Agent")) { work.answerReviews() }
            if pr.state == "OPEN" {
                menu.add(String(localized: "Merge"), submenu: work.mergeMenu { [weak self] in self?.reload() })
            }
            menu.addItem(.separator())
        }
        addCommon(menu)
        return menu
    }

    private func issueMoreMenu() -> NSMenu {
        let menu = NSMenu()
        if let issue = issueView?.issue, issue.state == "OPEN" {
            menu.add(String(localized: "Start on Own Branch")) { [weak self] in self?.startOnBranch() }
            menu.add(String(localized: "Start Here")) { [weak self] in self?.startHere() }
            menu.addItem(.separator())
        }
        addCommon(menu)
        return menu
    }

    private func addCommon(_ menu: NSMenu) {
        if let url = webURL {
            menu.add(String(localized: "Open in Browser")) { Forge.open(url) }
            menu.add(String(localized: "Copy Link")) { copyText(url) }
        }
        menu.add(String(localized: "Reload")) { [weak self] in self?.reload() }
    }

    /// A group on a branch of its own named after the issue, its agent given the issue to read before sending; the PR
    /// from that branch says it fixes the issue.
    func startOnBranch() {
        guard let issue = issueView?.issue else { return }
        IssueWork(app: app, repoId: repoId).startOnBranch(issue)
    }

    /// The default agent in the group on screen, on whatever it has out.
    func startHere() {
        guard let issue = issueView?.issue else { return }
        IssueWork(app: app, repoId: repoId).startHere(issue)
    }
}

/// Starting work from an issue: on a branch of its own (`task.fromIssue`), or in the group on screen.
@MainActor
struct IssueWork {
    let app: AppModel, repoId: String

    func startOnBranch(_ issue: GitHub.Issue) {
        Task {
            guard
                let made = await app.call(
                    TaskFromIssue(
                        repoId: repoId, ref: "#\(issue.number)", title: issue.title, body: issue.body, url: issue.url,
                        agent: app.catalog.defaultAgent))
            else { return }
            app.upsert(made.session)
            app.workbench.focus(session: made.session.id)
            NotificationCenter.default.post(name: PRWork.changed, object: nil)
        }
    }

    /// Its text typed in but not sent: whoever filed the issue wrote it, so the user reads it before the agent acts.
    func startHere(_ issue: GitHub.Issue) {
        guard let starter = app.workbench.starter, let wid = app.workbench.workspaceId else {
            NSSound.beep()
            return
        }
        Task {
            let vars = ["ref": "#\(issue.number)", "title": issue.title, "body": issue.body, "url": issue.url]
            guard let brief = await app.call(RecipeRender(id: wid, name: "issue", vars: vars)) else { return }
            starter.newAgent(nil, prompt: brief, draft: true)
        }
    }
}
