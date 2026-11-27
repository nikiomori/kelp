import AppKit
import Core
import DesignKit
import KelpKit

/// The tab's bar: where it goes, the one thing to do next as the accent's push button, Files, and the rest under ⋯.
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
        case .fix: trailing.append(primary(String(localized: "Fix with Agent")) { _ in work.fixChecks() })
        case .answer:
            trailing.append(primary(String(localized: "Send Review Comments to Agent")) { _ in work.answerReviews() })
        case .review:
            trailing.append(
                primary(String(localized: "Review with Agent")) { _ in work.review(base: view.baseRefName) })
        case .merge:
            trailing.append(
                primary(String(localized: "Merge…")) { merge in
                    work.mergeMenu(done: refresh).popUp(
                        positioning: nil, at: NSPoint(x: 0, y: merge.bounds.height + 4), in: merge)
                })
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
                primary(String(localized: "Open Its Group")) { [app] _ in app.workbench.show(workspace: folder.id) })
        } else if issue.state == "OPEN" {
            trailing.append(
                primary(String(localized: "Start on Own Branch")) { [weak self] _ in self?.startOnBranch() })
        }
        // Beside Start: the issue as a task, or the task it is already.
        let rows = TaskViews.rows([(repoId, app.latest(TasksEvent.self, repoId)?.pages ?? [])], session: app.session)
        if let known = rows.first(where: { $0.task.issue == issue.url }) {
            trailing.insert(
                TextButton(String(localized: "Show in Tasks")) { [app] in TaskActions.open(app, known) }, at: 0)
        } else {
            trailing.insert(
                TextButton(String(localized: "Add to Tasks")) { [app, repoId] in
                    Task { _ = await TaskActions.add(app, repo: repoId, text: issue.title, issue: issue.url) }
                }, at: 0)
        }
        trailing.append(moreButton(issueMenu: true))
        return Bar.content([route], trailing, stretching: route)
    }

    /// The button for the next thing to do: the system's push button in the accent, the one blue thing in the bar.
    /// `action` gets the button, so a menu can open under it.
    private func primary(_ title: String, _ action: @escaping @MainActor (NSView) -> Void) -> NSButton {
        MainActionButton(title, run: action)
    }

    private func moreButton(issueMenu: Bool) -> NSView {
        let more = IconButton(.symbol("ellipsis.circle"), tip: String(localized: "More Actions")) {}
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
        menu.add(String(localized: "Refresh")) { [weak self] in self?.reload() }   // the word every panel uses
    }

    /// Has an agent review the pull request in this tab against its base, as the bar's and ⋯'s Review with Agent.
    func reviewWithAgent() {
        guard let view = prView else { return }
        PRWork(app: app, repoId: repoId, pr: view.pr).review(base: view.baseRefName)
    }

    /// Starts a group on a branch of its own named after the issue, and gives its agent the issue to read before
    /// sending. The PR from that branch says it fixes the issue.
    func startOnBranch() {
        guard let issue = issueView?.issue else { return }
        IssueWork(app: app, repoId: repoId).startOnBranch(issue)
    }

    /// Starts the default agent in the group on screen, on whatever branch it has out.
    func startHere() {
        guard let issue = issueView?.issue else { return }
        IssueWork(app: app, repoId: repoId).startHere(issue)
    }
}

/// A bar's main action as the system draws it: a push button in the accent colour (macOS 26's primary tint, and the
/// bezel colour before it), as Run in a database's bar. Its click runs `run` with the button.
@MainActor
private final class MainActionButton: NSButton {
    private var run: (@MainActor (NSView) -> Void)?

    convenience init(_ title: String, run: @escaping @MainActor (NSView) -> Void) {
        self.init(frame: .zero)
        self.title = title
        self.run = run
        bezelStyle = .push
        if #available(macOS 26, *) {
            tintProminence = .primary
        } else {
            bezelColor = .controlAccentColor
        }
        target = self
        action = #selector(fire)
    }

    @objc private func fire() { run?(self) }
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
            TasksViewController.noteStarted(
                app, repo: repoId, title: issue.title, url: issue.url, chat: made.session.id)
            if made.setupNeedsTrust { await KelpFile(app: app).setup(made.worktree.id, pullRequest: nil) }
        }
    }

    /// Types the issue's text in without sending it, because whoever filed the issue wrote it, so the user reads it
    /// before the agent acts.
    func startHere(_ issue: GitHub.Issue) {
        Self.startHere(app, ["ref": "#\(issue.number)", "title": issue.title, "body": issue.body, "url": issue.url])
    }

    /// The default agent starts in the workspace on screen with the project's `issue` recipe typed in (as `kelp github
    /// issue` writes it: the title and body framed as someone else's words), a GitHub issue's or a tracker's task's.
    static func startHere(_ app: AppModel, _ vars: [String: String]) {
        guard let starter = app.workbench.starter, let wid = app.workbench.workspaceId else {
            NSSound.beep()
            return
        }
        Task {
            guard let brief = await app.call(RecipeRender(id: wid, name: "issue", vars: vars)) else { return }
            let repo = app.worktree(wid)?.repoId
            starter.newAgent(nil, prompt: brief, draft: true) { session in
                // The chat is the issue's task's: a line with the issue's link, written down if there is none.
                guard let repo, let title = vars["title"], let url = vars["url"] else { return }
                TasksViewController.noteStarted(app, repo: repo, title: title, url: url, chat: session.id)
            }
        }
    }
}
