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

    /// The chat tidying up the workspace's files, while it's open.
    static func chat(_ app: AppModel, _ worktreeId: String) -> Session? {
        app.sessions.first {
            $0.worktreeId == worktreeId && $0.titleManual && $0.title == title && $0.status != .exited
        }
    }
    /// That chat while its agent works or asks: the line shows it instead of the result.
    static func working(_ app: AppModel, _ worktreeId: String) -> Session? {
        chat(app, worktreeId).flatMap { [.working, .waiting].contains($0.status) ? $0 : nil }
    }

    /// The button: to the chat that's tidying up, else a new one with `agent` (nil: the default one).
    func run(agent: String? = nil) {
        if agent == nil, let chat = Self.working(app, worktreeId) {
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

    /// Review: every change against Kelp's copies, in the diff tab.
    func review() { app.workbench.open(TabURI.diff(worktreeId, source: "tidy")) }

    /// Keep Changes: the result leaves the panel; the copies stay in Kelp's home.
    func keep(_ done: @escaping () -> Void) async {
        guard await app.call(AddonsTidyEnd(worktreeId: worktreeId, undo: false)) != nil else { return }
        done()
    }

    /// Undo: after a question, Kelp puts its copies back; what the agent wrote stays beside them.
    func undo(_ done: @escaping () -> Void) async {
        let alert = NSAlert()
        alert.messageText = String(localized: "Put the instruction files back as they were?")
        alert.informativeText = String(
            localized: "Kelp puts back the copies it made before Tidy Up. What the agent wrote is kept beside them.")
        alert.addButton(withTitle: String(localized: "Undo"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard await runSheet(alert) == .alertFirstButtonReturn,
            await app.call(AddonsTidyEnd(worktreeId: worktreeId, undo: true)) != nil
        else { return }
        done()
    }
}
