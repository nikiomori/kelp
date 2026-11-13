import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// Tidy Up (Needs a Look › Instructions): the project's instruction files, all at once, go to an agent in a chat of its
/// own. Kelp copies them first and hands the agent the `tidyInstructions` recipe (`addons.tidy`); the agent reports,
/// and changes them only when the person says apply. Kelp writes none of the files itself.
@MainActor
struct TidyUp {
    let app: AppModel, worktreeId: String
    /// What the panel lists: the files to tidy are read from it.
    let items: [Addon]

    static var title: String { String(localized: "Tidy Up") }

    /// The chat tidying up the workspace's files, while it's open: the button goes to it instead of starting another.
    static func chat(_ app: AppModel, _ worktreeId: String) -> Session? {
        app.sessions.first {
            $0.worktreeId == worktreeId && $0.titleManual && $0.title == title && $0.status != .exited
        }
    }

    /// The button: to the chat that's tidying up, else a new one with `agent` (nil: the default one).
    func run(agent: String? = nil) {
        if agent == nil, let chat = Self.chat(app, worktreeId) {
            app.workbench.focus(session: chat.id)
            return
        }
        let paths = AddonGroups.tidied(items).compactMap(\.path)
        guard !paths.isEmpty else { return }
        let app = app, worktreeId = worktreeId
        Task {
            guard let prompt = await app.call(AddonsTidy(worktreeId: worktreeId, paths: paths)) else { return }
            let create = SessionCreate(
                worktreeId: worktreeId, agent: agent ?? app.catalog.defaultAgent, prompt: prompt, title: Self.title)
            guard let session = await app.call(create) else { return }
            app.upsert(session)
            app.workbench.open(TabURI.session(session.id))
        }
    }

    /// Tidy Up with: the agents on this Mac, for a run with another than the default one.
    func agents() -> NSMenu {
        let menu = NSMenu()
        for agent in app.catalog.installed(app.catalog.all) where agent.id != "shell" && agent.id != "custom" {
            menu.add(agent.name) { run(agent: agent.id) }
        }
        return menu
    }

    /// Compare with Before Tidy Up: the copy Kelp made against the file now (a memory index: its folders), in a tab.
    static func compare(_ app: AppModel, _ file: Addon) {
        guard let before = file.check?.before, let path = file.path else { return }
        let now = file.name == "MEMORY.md" ? (path as NSString).deletingLastPathComponent : path
        let command = ["git", "--no-pager", "diff", "--no-index", "--color=always", "--", before, now]
            .map(ShellQuote.word).joined(separator: " ")
        app.workbench.starter?.run(command: command, title: String(localized: "Before Tidy Up: \(file.name)"))
    }
}
