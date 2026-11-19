import Agents
import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// "Review with": another agent (another vendor's, say) reviews what the diff shows, in a session beside it, and
/// leaves its findings with `kelp comment add`. The findings appear in the diff with the agent's name, to pick from
/// (`DiffFindings`). The prompt is the `reviewWith` recipe, which a project's `.kelp.yaml` can change.
extension DiffViewController {
    /// Fills the menu with the agents and their models when it opens.
    func reviewItems(_ menu: NSMenu) {
        while menu.numberOfItems > 1 { menu.removeItem(at: 1) }   // the first is the pull-down's title
        let agents = app.catalog.installed.filter { Session.isAgent($0.id) }
        // Tidy Up's files aren't the project's code, and the agent that tidied them reports on them itself.
        guard sourcePicked != .tidy else {
            menu.addItem(withTitle: String(localized: "Only for the Project’s Code"), action: nil, keyEquivalent: "")
            return
        }
        guard !agents.isEmpty else {
            menu.addItem(withTitle: String(localized: "No Agent Installed"), action: nil, keyEquivalent: "")
            return
        }
        for agent in agents {
            guard !agent.models.isEmpty else {
                menu.add(agent.name) { [weak self] in self?.review(with: agent, model: nil) }
                continue
            }
            let sub = NSMenu()
            sub.add(String(localized: "Default Model")) { [weak self] in self?.review(with: agent, model: nil) }
            sub.addItem(.separator())
            for model in agent.models { sub.add(model) { [weak self] in self?.review(with: agent, model: model) } }
            menu.addItem(withTitle: agent.name, action: nil, keyEquivalent: "").submenu = sub
        }
    }

    private func review(with manifest: AgentManifest, model: String?) {
        guard let wid = worktreeId else { return }
        let (scope, command) = reviewScope(wid)
        Task {
            guard
                let prompt = await app.call(
                    RecipeRender(id: wid, name: "reviewWith", vars: ["scope": scope, "command": command])),
                let session = await app.call(
                    app.workbench.sized(
                        SessionCreate(
                            worktreeId: wid, agent: manifest.id, model: model, prompt: prompt,
                            title: Self.reviewTitle(manifest.name)
                        ).started(as: .reviewer), split: .right))
            else { return }
            app.upsert(session)
            reviewer = session.id
            app.workbench.open(TabURI.session(session.id), split: .right, focus: false)
            status.stringValue = String(
                localized: "\(manifest.name) is reviewing; its findings show here as it leaves them")
        }
    }

    /// The reviewer's tab title. Its `SessionRole.reviewer`, not the title, is what keeps findings from going to it.
    static func reviewTitle(_ agent: String) -> String { String(localized: "Review: \(agent)") }

    /// What the diff shows, in words and as the command that prints it, for the reviewer to read.
    func reviewScope(_ wid: String) -> (String, String) {
        if let single {
            let file = ShellQuote.word(single.file)
            if let commit = single.commit {
                return (
                    String(localized: "the changes to \(single.file) in commit \(commit)"),
                    "git show " + ShellQuote.word(commit) + " -- " + file
                )
            }
            let base = ShellQuote.word((app.worktree(wid)?.base ?? "main") + "...HEAD")
            let how: [DiffSource: String] = [
                .unstaged: "git diff", .staged: "git diff --cached", .branch: "git diff " + base
            ]
            return (
                String(localized: "the changes to \(single.file)"),
                (how[single.source] ?? "git diff HEAD") + " -- " + file
            )
        }
        switch sourcePicked {
        case .unstaged: return (String(localized: "the unstaged changes"), "git diff")
        case .staged: return (String(localized: "the staged changes"), "git diff --cached")
        case .branch:
            let base = app.worktree(wid)?.base ?? "main"
            return (
                String(localized: "this branch's changes since \(base)"),
                "git diff " + ShellQuote.word(base + "...HEAD")
            )
        case .commit:
            let hash = commitHash ?? "HEAD"
            return (String(localized: "commit \(hash)"), "git show " + ShellQuote.word(hash))
        case .turn:   // since the turn began: the turn's snapshot against the files now, new files listed too
            let tree = (turnPop.selectedItem?.representedObject as? SessionTurns.Mark)?.tree ?? "HEAD"
            return (
                String(localized: "the agent's turn: the files changed since it began"),
                "git diff " + ShellQuote.word(tree) + "; git status --short"
            )
        case .uncommitted, .tidy:   // Tidy Up's diff offers no reviewer (`reviewItems`)
            return (
                String(localized: "the uncommitted changes, new files included"), "git diff HEAD; git status --short"
            )
        }
    }

    /// The diff reads its comments again as the reviewer works (as the reviewer's status moves), so its findings show
    /// as it leaves them.
    func followReviewer() {
        track(
            owner: self, now: false, { [weak self] in self?.reviewerStatus },
            changed: { [weak self] _ in self?.reload() })
    }
    private var reviewerStatus: AgentStatus? {
        app.sessions.first { $0.id == reviewer }?.status
    }
}
