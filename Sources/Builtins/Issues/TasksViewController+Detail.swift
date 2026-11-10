// The task list's detail pane: a pull request, issue or ticket below the list, with its actions.
import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

extension TasksViewController {
    // MARK: detail
    private func label(
        _ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor
    )
        -> NSTextField
    {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .ui(size, weight: weight)
        field.textColor = color
        field.isSelectable = true
        // It wraps at the pane's width: measured for a wider one, its last lines were cut in the panel.
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    private func button(_ title: String, _ sym: String, _ action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: title, action: action)
        button.image = .symbol(sym)   // Kelp's own drawing where it has one (a branch, a pull request)
        button.imagePosition = .imageLeading
        button.bezelStyle = .push
        return button
    }

    func showDetail(_ row: Row?) {
        detail.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let row else {
            detail.addArrangedSubview(
                label(rows.isEmpty ? "" : String(localized: "Select an item"), color: .secondaryLabelColor))
            return
        }
        switch row {
        case .pr(let pr): prDetail(pr)
        case .jira(let issue):
            detail.addArrangedSubview(label("\(issue.key)  \(issue.title)", size: 17, weight: .semibold))
            detail.addArrangedSubview(jiraTransitions(issue.key, current: issue.status))
            detail.addArrangedSubview(
                button(String(localized: "Start Agent on This"), "sparkles") { [weak self] in
                    self?.startTask(ref: issue.key, title: issue.title, body: issue.description, url: issue.url)
                })
            body(issue.description)
        case .issue(let issue):
            detail.addArrangedSubview(label("#\(issue.number)  \(issue.title)", size: 17, weight: .semibold))
            detail.addArrangedSubview(
                button(String(localized: "Start Agent on This"), "sparkles") { [weak self] in
                    self?.startTask(ref: "#\(issue.number)", title: issue.title, body: issue.body, url: issue.url)
                })
            body(issue.body)
        case .linear(let issue):
            detail.addArrangedSubview(label("\(issue.identifier)  \(issue.title)", size: 17, weight: .semibold))
            detail.addArrangedSubview(statePicker(issue))
            detail.addArrangedSubview(
                button(String(localized: "Start Agent on This"), "sparkles") { [weak self] in
                    self?.startTask(
                        ref: issue.identifier, title: issue.title, body: issue.description ?? "", url: issue.url)
                })
            body(issue.description ?? "")
        case .item(let item):
            detail.addArrangedSubview(label(item.title, size: 17, weight: .semibold))
            detail.addArrangedSubview(
                label(String(localized: "Status: \(item.status ?? "—")"), color: .secondaryLabelColor))
        }
        if let url = row.url {
            detail.addArrangedSubview(button(String(localized: "Open on the Web"), "safari") { Forge.open(url) })
        }
    }

    private func body(_ text: String) {
        detail.addArrangedSubview(
            label(
                text.isEmpty ? String(localized: "No description.") : String(text.prefix(6000)),
                color: text.isEmpty ? .secondaryLabelColor : .labelColor))
    }

    /// The PR's folder: on its own branch, or on `pr-<n>` when that name was taken by another branch (`Git.fetchPullRequest`).
    private func worktreeFor(branch: String, pr number: Int) -> Worktree? {
        // This project's, and never its main checkout: a fork's PR from `main` isn't your main.
        let main = app.repo(repoId ?? "")?.path
        return app.worktrees.first {
            $0.repoId == repoId && ($0.branch == branch || $0.branch == "pr-\(number)") && !$0.archived
                && $0.path != main
        }
    }

    private func prDetail(_ pr: GitHub.PullRequest) {
        let app = self.app
        let number = pr.number, branch = pr.headRefName
        detail.addArrangedSubview(label("#\(number)  \(pr.title)", size: 17, weight: .semibold))
        let draft = pr.isDraft ? String(localized: " · draft") : ""
        let decision = pr.reviewDecision.map { " · " + $0.lowercased().replacingOccurrences(of: "_", with: " ") } ?? ""
        detail.addArrangedSubview(
            label(
                String(localized: "\(pr.author) wants to merge \(branch)\(draft)\(decision)"),
                color: .secondaryLabelColor))
        let wt = worktreeFor(branch: branch, pr: number)
        let actions = NSStackView()
        actions.orientation = .vertical   // three buttons in a line are wider than the panel
        actions.alignment = .leading
        actions.spacing = 8
        if wt == nil, let repoId {   // a folder of its own on the PR's head, as New Chat on Branch… › Pull Request makes
            actions.addArrangedSubview(
                button(String(localized: "Open in Worktree"), "arrow.triangle.branch") {
                    Task {
                        guard let made = await app.call(WorktreeCreate(repoId: repoId, branch: branch, pr: number))
                        else {
                            return
                        }
                        app.workbench.show(workspace: made.worktree.id)
                    }
                })
        }
        if let wt {
            actions.addArrangedSubview(
                button(String(localized: "Open Worktree"), "arrow.triangle.branch") {
                    app.workbench.show(workspace: wt.id)
                })
            actions.addArrangedSubview(
                button(String(localized: "Send Review Comments to Agent"), "text.bubble") { [weak self] in
                    self?.sendReview(number, wt)
                })
        }
        actions.addArrangedSubview(mergeButton(pr, wt))
        detail.addArrangedSubview(actions)
        if let why = Self.mergeBlock(pr) { detail.addArrangedSubview(label(why, color: .secondaryLabelColor)) }
        let checksBox = NSStackView()
        checksBox.orientation = .vertical
        checksBox.alignment = .leading
        checksBox.spacing = 4
        detail.addArrangedSubview(label(String(localized: "Checks"), weight: .semibold))
        detail.addArrangedSubview(checksBox)
        guard let repoId else { return }
        Task { [weak self] in
            guard let self else { return }
            let read = await app.tryCall(GitHubChecks(repoId: repoId, pr: number))
            let checks = read.value ?? []
            if let error = read.error {
                checksBox.addArrangedSubview(
                    label(String(localized: "Couldn't read the checks: \(error)"), color: .secondaryLabelColor))
            } else if checks.isEmpty {
                checksBox.addArrangedSubview(
                    label(String(localized: "No checks reported."), color: .secondaryLabelColor))
            }
            for check in checks {
                let icon =
                    check.bucket == "pass" ? "✓" : check.bucket == "fail" ? "✕" : check.bucket == "pending" ? "◌" : "–"
                let row = NSStackView(views: [
                    label("\(icon)  \(check.name)", color: check.bucket == "fail" ? .systemRed : .labelColor)
                ])
                row.spacing = 8
                if check.bucket == "fail", let run = check.runId, let wt {
                    row.addArrangedSubview(
                        button(String(localized: "Fix with Agent"), "wrench.and.screwdriver") { [weak self] in
                            self?.fixCheck(check.name, run, wt)
                        })
                }
                checksBox.addArrangedSubview(row)
            }
        }
    }

    private func statePicker(_ issue: LinearIssue) -> NSView {
        let pop = NSPopUpButton()
        pop.addItem(withTitle: issue.state.name)
        Task {
            guard let states = await app.quiet(LinearStates(teamId: issue.team.id)) else { return }   // keeps the current state
            pop.removeAllItems()
            for state in states {
                pop.addItem(withTitle: state.name)
                pop.lastItem?.representedObject = state.id
            }
            pop.selectItem(withTitle: issue.state.name)
        }
        let id = issue.id
        let sink = ClosureTarget { [weak pop, app] in
            guard let sid = pop?.selectedItem?.representedObject as? String else { return }
            Task { await app.call(LinearSetState(issueId: id, stateId: sid)) }
        }
        pop.target = sink
        pop.action = #selector(ClosureTarget.fire)
        objc_setAssociatedObject(pop, "sink", sink, .OBJC_ASSOCIATION_RETAIN)
        let row = NSStackView(views: [NSTextField(labelWithString: String(localized: "State:")), pop])
        row.spacing = 6
        return row
    }

    private func jiraTransitions(_ key: String, current: String) -> NSView {
        let pop = NSPopUpButton()
        pop.addItem(withTitle: current.isEmpty ? String(localized: "Status") : current)
        Task {
            let ts = await app.quiet(JiraTransitions(key: key)) ?? []   // none offered: the status stays as shown
            for transition in ts {
                pop.addItem(withTitle: "→ " + transition.name)
                pop.lastItem?.representedObject = transition.id
            }
        }
        let sink = ClosureTarget { [weak pop, weak self, app] in
            guard let id = pop?.selectedItem?.representedObject as? String else { return }
            Task {
                if await app.call(JiraTransitionIssue(key: key, id: id)) != nil {
                    self?.status.stringValue = String(localized: "Moved \(key)")
                }
            }
        }
        pop.target = sink
        pop.action = #selector(ClosureTarget.fire)
        objc_setAssociatedObject(pop, "sink", sink, .OBJC_ASSOCIATION_RETAIN)
        let row = NSStackView(views: [NSTextField(labelWithString: String(localized: "Status:")), pop])
        row.spacing = 6
        return row
    }

    private func agentSession(_ wt: Worktree) -> String? {
        app.sessions.last {
            $0.worktreeId == wt.id && $0.status != .exited && $0.agent != "shell" && $0.agent != "custom"
        }?.id
    }
    private func sendRecipe(_ name: String, _ wt: Worktree, _ vars: [String: String]) async {
        guard let sid = agentSession(wt) else {
            status.stringValue = String(localized: "No running agent in \(wt.branch) — start one first")
            return
        }
        guard await GitFix(app).type(name, worktree: wt.id, vars: vars, into: sid) else { return }
        status.stringValue = String(
            localized: "Typed into \(app.session(sid)?.displayTitle ?? "agent") — press Return there to send")
    }
    private func fixCheck(_ name: String, _ run: Int, _ wt: Worktree) {
        guard let repoId else { return }
        Task {
            let log = await app.call(GitHubFailedLog(repoId: repoId, runId: run)) ?? ""
            await sendRecipe("fixCI", wt, ["check": name, "error": log])
        }
    }
    private func sendReview(_ n: Int, _ wt: Worktree) {
        guard let repoId else { return }
        Task {
            guard let cs = await app.call(GitHubReviewComments(repoId: repoId, pr: n)) else { return }   // the banner says why
            guard !cs.isEmpty else {
                status.stringValue = String(localized: "No review comments")
                return
            }
            await sendRecipe("review", wt, ["comments": Self.forAgent(cs)])
        }
    }
}
