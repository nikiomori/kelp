import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// Tidy Up (Needs a Look › Instructions) hands all of the project's instruction files at once to an agent, in a chat of
/// its own. Kelp copies the files first and hands the agent the `tidyInstructions` recipe (`addons.tidy`). The agent
/// reports, and changes the files only when the person says to apply. Kelp writes none of the files itself.
@MainActor
struct TidyUp {
    let app: AppModel, worktreeId: String
    /// The items the panel lists, which the files to tidy are read from.
    let items: [Addon]

    static var title: String { String(localized: "Tidy Up") }

    /// The chat that is tidying up the workspace's files, while that chat is open.
    static func chat(_ app: AppModel, _ worktreeId: String) -> Session? {
        app.sessions.first {
            $0.worktreeId == worktreeId && $0.titleManual && $0.title == title && $0.status != .exited
        }
    }
    /// The Tidy Up chat while its agent works or asks. Meanwhile the Instructions row shows that chat instead of the
    /// result.
    static func working(_ app: AppModel, _ worktreeId: String) -> Session? {
        chat(app, worktreeId).flatMap { [.working, .waiting].contains($0.status) ? $0 : nil }
    }

    /// Answers the button. It goes to the chat that is tidying up, else starts a new chat with `agent` (nil for the
    /// default agent).
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
            let create = app.workbench.sized(
                SessionCreate(
                    worktreeId: worktreeId, agent: agent ?? app.catalog.defaultAgent, prompt: prompt, title: Self.title)
            )
            guard let session = await app.call(create) else { return }
            app.upsert(session)
            app.workbench.open(TabURI.session(session.id))
        }
    }

    /// The Tidy Up with menu lists the agents on this Mac, to run Tidy Up with an agent other than the default.
    func agents() -> NSMenu {
        let menu = NSMenu()
        for agent in app.catalog.installed(app.catalog.all) where Session.isAgent(agent.id) {
            menu.add(agent.name) { run(agent: agent.id) }
        }
        return menu
    }

    /// Review shows every change against Kelp's copies in the diff tab.
    func review() { app.workbench.open(TabURI.diff(worktreeId, source: .tidy)) }

    /// Keep Changes takes the result off the panel, and the copies stay in Kelp's home.
    func keep(_ done: @escaping () -> Void) async {
        guard await app.call(AddonsTidyEnd(worktreeId: worktreeId, undo: false)) != nil else { return }
        done()
    }

    /// Undo asks first, then Kelp puts its copies back. What the agent wrote stays beside them.
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
