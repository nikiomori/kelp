import AppKit
import Agents
import Core
import KelpKit
import WorkbenchKit

/// "Review with": another agent (another vendor's, say) reviews what the diff shows, in a session beside it, and leaves
/// its findings with `kelp comment add`; they appear in the diff with its name, to pick from (`DiffFindings`). The prompt
/// is the `reviewWith` recipe, which a project's `.kelp.yaml` can change.
extension DiffViewController {
    /// The menu's agents and their models, made when it opens.
    func reviewItems(_ m: NSMenu) {
        while m.numberOfItems > 1 { m.removeItem(at: 1) }   // the first is the pull-down's title
        let agents = app.catalog.installed(app.catalog.all).filter { $0.id != "shell" && $0.id != "custom" }
        guard !agents.isEmpty else { m.addItem(withTitle: String(localized: "No Agent Installed"), action: nil, keyEquivalent: ""); return }
        for a in agents {
            guard !a.models.isEmpty else { m.add(a.name) { [weak self] in self?.review(with: a, model: nil) }; continue }
            let sub = NSMenu()
            sub.add(String(localized: "Default Model")) { [weak self] in self?.review(with: a, model: nil) }
            sub.addItem(.separator())
            for model in a.models { sub.add(model) { [weak self] in self?.review(with: a, model: model) } }
            m.addItem(withTitle: a.name, action: nil, keyEquivalent: "").submenu = sub
        }
    }

    private func review(with a: AgentManifest, model: String?) {
        guard let wid = worktreeId else { return }
        let (scope, command) = reviewScope(wid)
        Task {
            guard let prompt = await app.call(RecipeRender(id: wid, name: "reviewWith", vars: ["scope": scope, "command": command])),
                  let s = await app.call(SessionCreate(worktreeId: wid, agent: a.id, model: model, prompt: prompt,
                                                       title: Self.reviewTitle(a.name))) else { return }
            app.upsert(s)
            reviewer = s.id
            app.workbench.open(TabURI.session(s.id), split: .right, focus: false)
            status.stringValue = String(localized: "\(a.name) is reviewing; its findings show here as it leaves them")
        }
    }

    /// The reviewer's tab title, by which Send to Agent knows it isn't the agent findings go to.
    static func reviewTitle(_ agent: String) -> String { String(localized: "Review: \(agent)") }

    /// What the diff shows, in words and as the command that prints it, for the reviewer.
    func reviewScope(_ wid: String) -> (String, String) {
        if let s = single {
            let f = IDE.shellWord(s.file)
            if let c = s.commit { return (String(localized: "the changes to \(s.file) in commit \(c)"), "git show " + IDE.shellWord(c) + " -- " + f) }
            let base = IDE.shellWord((app.worktree(wid)?.base ?? "main") + "...HEAD")
            let how = ["unstaged": "git diff", "staged": "git diff --cached", "branch": "git diff " + base]
            return (String(localized: "the changes to \(s.file)"), (how[s.source] ?? "git diff HEAD") + " -- " + f)
        }
        switch source.indexOfSelectedItem {
        case 1: return (String(localized: "the unstaged changes"), "git diff")
        case 2: return (String(localized: "the staged changes"), "git diff --cached")
        case 3:
            let base = app.worktree(wid)?.base ?? "main"
            return (String(localized: "this branch's changes since \(base)"), "git diff " + IDE.shellWord(base + "...HEAD"))
        case 4:
            let hash = commitHash ?? "HEAD"
            return (String(localized: "commit \(hash)"), "git show " + IDE.shellWord(hash))
        case 5:   // since the turn began: its snapshot against the files now, new ones listed too
            let tree = (turnPop.selectedItem?.representedObject as? SessionTurns.Mark)?.tree ?? "HEAD"
            return (String(localized: "the agent's turn: the files changed since it began"),
                    "git diff " + IDE.shellWord(tree) + "; git status --short")
        default: return (String(localized: "the uncommitted changes, new files included"), "git diff HEAD; git status --short")
        }
    }

    /// The diff reads its comments again as the reviewer works (its status moves), so its findings come as it leaves them.
    func followReviewer() {
        track(owner: self, now: false, { [weak self] in self?.reviewerStatus }, changed: { [weak self] _ in self?.reload() })
    }
    private var reviewerStatus: AgentStatus? {
        app.sessions.first { $0.id == reviewer }?.status
    }
}
