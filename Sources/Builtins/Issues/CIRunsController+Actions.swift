// What can be done to a CI run: run a workflow, the right-click menu, hand a failure to an agent.
import AppKit
import Core
import DesignKit
import KelpKit

extension CIRunsController {
    /// The right-click menu: what can be done to this run, job or step now.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let item = outline.item(atRow: outline.clickedRow) as? Item, let worktree else { return }
        let act = actions(worktree)
        switch item.kind {
        case .run(let run): addRun(run, act, to: menu)
        case .job(let job, _):
            if job.failed { menu.add(String(localized: "Fix with Agent")) { act.fix(job) } }
            if job.status == "completed" { menu.add(String(localized: "Re-run This Job")) { act.rerunJob(job.id) } }
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            if let url = job.url { addLink(menu, url) }
        case .step(let step):
            if let job = job(of: item), job.status == "completed" {
                menu.add(String(localized: "Show in Log")) { [app] in
                    CILogTab.open(app, worktree: act.worktree, job: job, step: step.name)
                }
            }
            if let url = job(of: item)?.url, let number = step.number {
                menu.add(String(localized: "Open in Browser")) { Forge.open("\(url)#step:\(number):1") }
            }
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            menu.add(String(localized: "Copy Step Name")) {
                copyText(step.name)
            }
        case .fold: break
        }
    }

    private func addRun(_ run: CIRuns.Run, _ act: CIActions, to menu: NSMenu) {
        if run.failed {
            menu.add(String(localized: "Fix with Agent")) { [weak self] in self?.fix(run, in: act.worktree) }
            menu.add(String(localized: "Re-run Failed")) { act.rerunFailed(run.id) }
        }
        if run.finished {
            menu.add(String(localized: "Re-run All")) { act.rerunAll(run.id) }
        } else {
            menu.add(String(localized: "Cancel Run…")) { act.cancel(run) }
        }
        menu.addItem(.separator())
        if run.sha != nil { menu.add(String(localized: "Show Commit")) { act.showCommit(run) } }
        addLink(menu, run.url)
    }

    private func addLink(_ menu: NSMenu, _ url: String) {
        menu.add(String(localized: "Open in Browser")) { Forge.open(url) }
        menu.addItem(.separator())
        menu.add(String(localized: "Copy Link")) {
            copyText(url)
        }
    }
    /// Types the run's failure into the workspace's agent, for the user to send.
    private func fix(_ run: CIRuns.Run, in worktree: String) {
        let app = app
        guard let repo = app.worktree(worktree)?.repoId else { return }
        Task {
            let log = await app.call(GitHubFailedLog(repoId: repo, runId: run.id)) ?? ""
            GitFix(app).send("fixCI", worktree: worktree, vars: ["check": run.workflow, "error": log])
        }
    }
}

extension CIRunsController {
    // MARK: actions

    var allRuns: [CIRuns.Run] { runs.compactMap { if case .run(let run) = $0.kind { run } else { nil } } }
    func run(_ id: Int) -> CIRuns.Run? { allRuns.first { $0.id == id } }

    private func actions(_ worktree: String) -> CIActions {
        CIActions(app: app, worktree: worktree) { [weak self] in self?.reload() }
    }

    /// The panel's actions as commands (`IssuesBuiltin`), for the run picked in the list.
    enum Command { case rerunFailed, rerunAll, cancel, runWorkflow, fix, openLog }

    /// What `what` does now, or nil when the panel isn't on screen or the pick can't take it.
    func command(_ what: Command) -> (@MainActor () -> Void)? {
        guard isViewLoaded, view.window != nil, let worktree else { return nil }
        if what == .runWorkflow {
            guard !workflows.isEmpty else { return nil }
            return { [weak self] in self?.runWorkflow() }
        }
        guard let pick = picked else { return nil }
        let run = pick.run, job = pick.job, act = actions(worktree)
        switch what {
        case .rerunFailed:
            guard run.failed else { return nil }
            return { act.rerunFailed(run.id) }
        case .rerunAll:
            guard run.finished else { return nil }
            return { act.rerunAll(run.id) }
        case .cancel:
            guard !run.finished else { return nil }
            return { act.cancel(run) }
        case .fix:
            if let job {
                guard job.failed else { return nil }
                return { act.fix(job) }
            }
            guard run.failed else { return nil }
            return { [weak self] in self?.fix(run, in: worktree) }
        case .openLog:
            guard let job, job.status == "completed" else { return nil }
            return { [app] in CILogTab.open(app, worktree: worktree, job: job) }
        case .runWorkflow: return nil
        }
    }

    /// The run picked in the list, and its job when a job or one of its steps is picked.
    private var picked: (run: CIRuns.Run, job: CIRuns.Job?)? {
        var up = outline.item(atRow: outline.selectedRow) as? Item
        while let item = up {
            switch item.kind {
            case .run(let run): return (run, nil)
            case .job(let job, let id): return run(id).map { ($0, job) }
            case .step, .fold: up = outline.parent(forItem: item) as? Item
            }
        }
        return nil
    }

    @objc func runWorkflow() {
        let menu = NSMenu()
        // Each asks before it runs (`dispatch`), so each ends in "…".
        for wf in workflows { menu.add(wf.name + "…") { [weak self] in self?.dispatch(wf) } }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: workflowsButton.bounds.height + 4), in: workflowsButton)
    }

    /// Asks for the workflow's inputs in a form, then runs `gh workflow run` on this branch.
    private func dispatch(_ wf: CIRuns.Workflow) {
        guard let worktree else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Run “\(wf.name)” on \(branchName)?")
        var fields: [(String, NSView)] = []
        let form = NSGridView()
        form.rowAlignment = .firstBaseline
        for input in wf.inputs {
            let control: NSView
            if !input.options.isEmpty {
                let popUp = NSPopUpButton()
                popUp.addItems(withTitles: input.options)
                popUp.selectItem(withTitle: input.defaultValue)
                control = popUp
            } else {
                let field = NSTextField(string: input.defaultValue)
                field.placeholderString = input.description
                // The form is a question sheet's width, its names beside the fields, as in a new chat's sheet.
                field.widthAnchor.constraint(
                    equalToConstant: Metrics.alertAccessory - Metrics.formLabel - Metrics.gapWide
                ).isActive = true
                control = field
            }
            fields.append((input.name, control))
            form.addRow(with: [NSTextField(labelWithString: input.name + (input.required ? " *" : "")), control])
        }
        if !wf.inputs.isEmpty { alert.accessoryView = form }
        alert.informativeText =
            wf.inputs.isEmpty
            ? String(localized: "It runs on GitHub Actions.") : String(localized: "Inputs from \(wf.file):")
        alert.addButton(withTitle: String(localized: "Run"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        Task {
            guard await runSheet(alert) == .alertFirstButtonReturn else { return }
            var inputs: [String: String] = [:]
            for (name, control) in fields {
                inputs[name] =
                    (control as? NSPopUpButton)?.titleOfSelectedItem ?? (control as? NSTextField)?.stringValue ?? ""
            }
            if await app.call(CIDispatch(worktreeId: worktree, workflow: wf.file, branch: branchName, inputs: inputs))
                != nil
            {
                Banner.show(String(localized: "Started \(wf.name)"))
                reload()
            }
        }
    }
}
