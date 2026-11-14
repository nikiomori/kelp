import Agents
import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// An agent writes the commit: its logo in the Message field asks it (the chevron beside picks another, and a model).
/// It runs as a session with no tab, reads the changes and proposes commits with `kelp commit add` (the `commitPlan`
/// recipe); it never stages or commits. One commit that takes every file fills the Message field; anything else is a
/// plan over the button, edited before Kelp makes its commits one by one.
struct AgentCommit {
    let agentId: String, agent: String
    /// What the user had written: it goes to the agent as a note.
    let hint: String
    /// How many files it reads, for the words in the field.
    let files: Int
    var session: String?
    var status: AgentStatus?
    var sawWork = false
    /// Its tab was asked for (Show): no longer kept out of sight.
    var shown = false
}

/// The words under the field when it proposed nothing; a message it wrote needs none, being in the field (⌘Z takes it
/// back, the logo asks again).
struct AgentNote {
    let agentId: String, text: String
}

extension SourceControlController {
    /// Claude Code's quickest model, when the user hasn't picked one: a commit message needs no more.
    static let quickModels: Set<String> = ["haiku"]

    var lastAgent: AgentManifest? {
        let agents = commitAgents
        let id = UserDefaults.standard.string(forKey: "scm.commitAgent")
        return agents.first { $0.id == id } ?? agents.first { $0.id == "claude" } ?? agents.first
    }
    private var commitAgents: [AgentManifest] {
        app.catalog.installed(app.catalog.all).filter { $0.id != "shell" && $0.id != "custom" }
    }
    private func model(for a: AgentManifest) -> String? {
        if let picked = UserDefaults.standard.string(forKey: "scm.commitModel.\(a.id)") {
            return picked.isEmpty ? nil : picked
        }
        return a.models.first { Self.quickModels.contains($0) }
    }

    @objc func askLastAgent() {
        guard let a = lastAgent else { return agentMenu() }
        ask(a, model: model(for: a))
    }

    /// The installed agents, each with its models; the one asked last ticked.
    @objc func agentMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: String(localized: "Write the Message With"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let agents = commitAgents
        if agents.isEmpty {
            menu.addItem(withTitle: String(localized: "No Agent Installed"), action: nil, keyEquivalent: "")
        }
        for a in agents {
            let item = menu.add(a.name) { [weak self] in self?.ask(a, model: self?.model(for: a)) }
            item.image = app.catalog.icon(a.id, size: 16)
            item.state = a.id == lastAgent?.id ? .on : .off
            guard !a.models.isEmpty else { continue }
            let sub = NSMenu(), chosen = model(for: a)
            let byDefault = sub.add(String(localized: "Default Model")) { [weak self] in self?.ask(a, model: nil) }
            byDefault.state = chosen == nil ? .on : .off
            sub.addItem(.separator())
            for m in a.models {
                sub.add(m) { [weak self] in self?.ask(a, model: m) }.state = m == chosen ? .on : .off
            }
            item.submenu = sub
        }
        let at = agentUI.chevron
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: at.bounds.height + 4), in: at)
    }

    /// `a` reads what a commit would take now (the staged files, else every change) and proposes its commits.
    func ask(_ a: AgentManifest, model: String?) {
        guard let wid = worktreeId, agentCommits[wid] == nil, !busy, !changes.isEmpty else { return NSSound.beep() }
        guard !changes.contains(where: \.conflicted) else {
            return Banner.show(String(localized: "Resolve the merge conflicts before asking for commits."))
        }
        UserDefaults.standard.set(a.id, forKey: "scm.commitAgent")
        UserDefaults.standard.set(model ?? "", forKey: "scm.commitModel.\(a.id)")
        let all = GitCommit.takesEverything(changes)
        let hint = message.string.trimmingCharacters(in: .whitespacesAndNewlines)
        agentCommits[wid] = AgentCommit(
            agentId: a.id, agent: a.name, hint: hint, files: all ? changes.count : changes.filter(\.staged).count)
        plans[wid] = nil
        notes[wid] = nil
        showAgentCommit()
        // A remote project's agent runs here, where `kelp` is, and reads the changes on the host over Kelp's own
        // connection to it (no login asked).
        let remote = app.worktree(wid).flatMap { RemoteHost.of($0.path) }
        var command = all ? "git status --short; git diff HEAD" : "git diff --cached"
        if let remote {
            command =
                ([remote.ssh] + remote.sshArgs(tty: false) + ["cd \(RemoteHost.cdArg(remote.path)) && \(command)"])
                .map(ShellQuote.word).joined(separator: " ")
        }
        let vars = [
            "scope": all ? "the uncommitted changes, new files included" : "the staged changes",
            "command": command,
            "hint": hint.isEmpty ? "" : "\n\nWhat the user wrote about them: \(hint)"
        ]
        Task {
            guard let prompt = await app.call(RecipeRender(id: wid, name: "commitPlan", vars: vars)),
                let session = await app.call(
                    SessionCreate(
                        cwd: remote == nil ? nil : NSHomeDirectory(), worktreeId: wid, agent: a.id, model: model,
                        prompt: prompt,
                        title: String(localized: "Commit: \(a.name)")))
            else {
                agentCommits[wid] = nil
                return showAgentCommit(in: wid)
            }
            guard agentCommits[wid] != nil else {   // stopped while it started
                await app.call(SessionKill(id: session.id))
                return
            }
            agentCommits[wid]?.session = session.id
            app.upsert(session)
            app.workbench.hideTab(uri: TabURI.session(session.id))   // put on screen before its id came back
            showAgentCommit(in: wid)
        }
    }

    /// The agents' statuses as they move, whichever workspace is on screen: one that has worked and stopped is done.
    func followAgentCommits() {
        track(owner: self) { [weak self, app] in
            let sessions = app.sessions   // read even with no agent asked: what's observed is what was read
            return (self?.agentCommits ?? [:]).compactMapValues { run in
                run.session.map { sid in sessions.first { $0.id == sid }?.status ?? .exited }
            }
        } changed: { [weak self] statuses in
            for (wid, status) in statuses { self?.moved(wid, status) }
        }
    }

    private func moved(_ wid: String, _ status: AgentStatus) {
        guard var run = agentCommits[wid] else { return }
        if status == .working { run.sawWork = true }
        run.status = status
        agentCommits[wid] = run
        switch status {
        case .exited, .error: finishAgent(wid)
        case .done where run.sawWork, .idle where run.sawWork: finishAgent(wid)
        default: showAgentCommit(in: wid)
        }
    }

    @objc func stopAgentCommit() {
        guard let wid = worktreeId, let run = agentCommits.removeValue(forKey: wid) else { return }
        Task {
            if let sid = run.session { await app.call(SessionKill(id: sid)) }
            _ = await app.quiet(CommitPlanTake(worktreeId: wid))   // what it proposed before the stop goes too
        }
        showAgentCommit()
    }

    /// The agents writing commits that keep out of sight: no tab, no row in the sidebar, until Show.
    var hiddenAgentSessions: Set<String> {
        Set(agentCommits.values.filter { !$0.shown }.compactMap(\.session))
    }

    @objc func showAgentSession() {
        guard let wid = worktreeId, let sid = agentCommits[wid]?.session else { return }
        agentCommits[wid]?.shown = true
        app.workbench.open(TabURI.session(sid), split: .right)
    }

    /// The agent stopped: what it proposed becomes the message or the plan, and its session ends; when it proposed
    /// nothing, its tab opens beside instead, to see why.
    private func finishAgent(_ wid: String) {
        guard let run = agentCommits.removeValue(forKey: wid) else { return }
        Task {
            let proposed = await app.quiet(CommitPlanTake(worktreeId: wid)) ?? []
            let status = await app.quiet(GitStatus(id: wid)) ?? []
            let all = GitCommit.takesEverything(status)
            let scope = status.filter { all || ($0.staged && !$0.conflicted) }.map(\.path)
            let plan = CommitPlan(agent: run.agent, proposed: proposed, changed: scope)
            if let sid = run.session {
                if plan.commits.isEmpty {
                    app.workbench.open(TabURI.session(sid), split: .right, focus: false)
                } else {
                    await app.call(SessionKill(id: sid))
                }
            }
            took(plan, from: run, scope: scope, in: wid)
        }
    }

    private func took(_ plan: CommitPlan, from run: AgentCommit, scope: [String], in wid: String) {
        if plan.commits.isEmpty {
            notes[wid] = AgentNote(agentId: run.agentId, text: String(localized: "No commits from \(run.agent)"))
        } else if plan.commits.count == 1, Set(plan.files) == Set(scope), let only = plan.commits.first {
            guard wid == worktreeId else {
                drafts[wid] = only.message
                return
            }
            showAgentCommit()   // the field back on screen first: measured hidden, it kept one line
            write(only.message)
            return
        } else {
            plans[wid] = plan
        }
        showAgentCommit(in: wid)
    }

    /// The message in the field as if typed over what was there: ⌘Z brings the user's words back.
    private func write(_ text: String) {
        let all = NSRange(location: 0, length: (message.string as NSString).length)
        guard message.shouldChangeText(in: all, replacementString: text) else { return }
        message.replaceCharacters(in: all, with: text)
        message.didChangeText()   // the field grows to it (onChange)
        message.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        message.window?.makeFirstResponder(message)
        DispatchQueue.main.async { [weak self] in self?.messageChanged() }   // once the field has its width again
    }

    /// The same agent once more, from what the field says now.
    @objc func askAgainForCommits() {
        guard let wid = worktreeId else { return }
        notes[wid] = nil
        askLastAgent()
    }

    func discardPlan() {
        guard let wid = worktreeId else { return }
        plans[wid] = nil
        showAgentCommit()
    }

    func editPlan(_ change: (inout CommitPlan) -> Void) {
        guard let wid = worktreeId, var plan = plans[wid] else { return }
        change(&plan)
        plans[wid] = plan.commits.isEmpty ? nil : plan
        showAgentCommit()
    }

    /// The plan's commits, one by one from the top, each taking only its files: a failure stops at that one (the banner
    /// offers the agent's fix), what went in stays, and the rest wait for the button again.
    func makeCommits(push: Bool) {
        guard let wid = worktreeId, let plan = plans[wid], !busy else { return NSSound.beep() }
        if plan.commits.contains(where: { $0.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return Banner.show(String(localized: "Write a message for each commit first."), style: .error)
        }
        begin(wid)
        Task { [self] in
            var made: [String] = []
            for commit in plan.commits {
                let result = await app.tryCall(
                    GitCommitPaths(worktreeId: wid, files: commit.files, message: commit.message))
                guard let hash = result.value else {
                    if let error = result.error { GitFix(app).offer(error, recipe: "fixCommit", worktree: wid) }
                    break
                }
                made.append(hash)
                plans[wid]?.commits.removeFirst()
                if plans[wid]?.commits.isEmpty == true { plans[wid] = nil }
                showAgentCommit(in: wid)
            }
            let all = plans[wid] == nil
            var pushed = false
            if all, push {
                let refused = await GitSync.run(app, wid, ["push"])
                if let refused { GitFix(app).offer(refused, recipe: "fixPush", worktree: wid) }
                pushed = refused == nil
            }
            end(wid)
            finish(
                push ? String(localized: "Pushed") : String(localized: "Committed"), ok: push ? pushed : all,
                quiet: true, in: wid)
            reloadAll()
            guard let head = made.last, !pushed else { return }
            let done = Array(plan.commits.prefix(made.count))
            Banner.show(
                String(localized: "\(made.count) commits made"),
                action: (String(localized: "Undo"), { [weak self] in self?.undoCommits(wid, head: head, done) }))
        }
    }

    /// The commits just made, undone: their changes staged again and their part of the plan back over what's left.
    private func undoCommits(_ wid: String, head: String, _ done: [CommitPlan.Commit]) {
        Task {
            guard await app.call(GitUndoCommits(worktreeId: wid, head: head, count: done.count)) != nil else { return }
            var plan = plans[wid] ?? CommitPlan(agent: lastAgent?.name ?? "", proposed: [], changed: [])
            plan.commits = done + plan.commits
            plans[wid] = plan
            showAgentCommit(in: wid)
            reloadAll()
        }
    }

    /// A file row's menu while there's a plan: which commit it goes into, another, a new one, or none.
    func planItems(_ menu: NSMenu, _ file: String, _ plan: CommitPlan) {
        menu.addItem(.separator())
        let now = plan.number(of: file)
        for i in plan.commits.indices {
            let title =
                now == i + 1 ? String(localized: "In Commit \(i + 1)") : String(localized: "Move to Commit \(i + 1)")
            menu.add(title) { [weak self] in self?.editPlan { $0.move(file, to: i) } }.state = now == i + 1 ? .on : .off
        }
        menu.add(String(localized: "Move to a New Commit")) { [weak self] in
            self?.editPlan { $0.move(file, to: $0.commits.count) }
        }
        if now != nil {
            menu.add(String(localized: "Leave Out of the Commits")) { [weak self] in
                self?.editPlan { $0.move(file, to: nil) }
            }
        }
    }

    func showAgentCommit(in wid: String) {
        if wid == worktreeId { showAgentCommit() }
    }
}
