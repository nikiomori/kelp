import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// Sync… in Artifacts Overview: Kelp can't sign in to claude.ai, but Claude can save a page's files to disk with its
/// artifact tools. The sheet counts the copies first; on Sync, Kelp starts a Claude chat that runs
/// `kelp artifact sync --all`, as Tidy Up starts its own, and with the box ticked it adds a nightly routine that does
/// the same. Limit: only Claude Code has those tools, so only it is asked.
@MainActor
enum OverviewSync {
    static let title = "Sync artifacts"
    static let prompt = """
        Run `kelp artifact sync --all` and do what it says, page by page, without reading the pages into this chat. \
        When `kelp artifact sync --check --all` says every page is whole, or what is left can't be fetched, say so in \
        one line.
        """

    static func ask(_ model: OverviewModel) {
        let pages = model.pages.filter { PageCopies.syncs($0.item) }
        let partial = pages.count { $0.item.copy == .partial }, none = pages.count { $0.item.copy == nil }
        let alert = NSAlert()
        alert.messageText = String(localized: "Sync Pages from claude.ai")
        let short = partial + none
        let counts = String(
            localized: "\(pages.count - short) whole on this Mac, \(partial) without pictures, \(none) with no copy.")
        let next =
            short == 0
            ? String(localized: "Every page opens without the network.")
            : String(
                localized: "Kelp can't sign in to claude.ai: a Claude chat saves the rest to disk and checks them.")
        alert.informativeText = counts + " " + next
        let nightly = NSButton(
            checkboxWithTitle: String(localized: "Then keep them in sync every night (a routine)"), target: nil,
            action: nil)
        nightly.state = .on
        if short > 0 {
            alert.accessoryView = nightly
            alert.addButton(withTitle: String(localized: "Sync \(short) Pages"))
            alert.addButton(withTitle: String(localized: "Cancel"))
        } else {
            alert.addButton(withTitle: String(localized: "OK"))
        }
        Task {
            guard await runSheet(alert) == .alertFirstButtonReturn, short > 0 else { return }
            await start(model.app, nightly: nightly.state == .on)
        }
    }

    /// Starts the chat in the project on screen (else the first), and the routine when asked.
    private static func start(_ app: AppModel, nightly: Bool) async {
        guard let worktree = app.worktree(app.workbench.workspaceId) ?? app.worktrees.first(where: { !$0.archived })
        else { return }
        let create = app.workbench.sized(
            SessionCreate(worktreeId: worktree.id, agent: Session.claudeAgent, prompt: prompt, title: title))
        guard let session = await app.call(create) else { return }
        app.upsert(session)
        app.workbench.open(TabURI.session(session.id))
        guard nightly, let known = await app.call(RoutineList()),
            !known.routines.contains(where: { $0.prompt == prompt })
        else { return }
        let routine = Routine(
            name: title, repoId: worktree.repoId, agent: Session.claudeAgent, prompt: prompt, every: .daily,
            time: 3 * 60)
        await app.call(RoutineSet(routine: routine))
    }
}
