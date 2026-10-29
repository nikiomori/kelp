import AppKit
import Core
import WorkbenchKit

/// The window a sheet goes on: key / main are nil while Kelp isn't the active app, the sheet still belongs on its window.
/// One that already shows a sheet queues the next.
@MainActor
private var sheetWindow: NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain } }

/// An alert as a sheet on the front window, awaited (native, no nested modal loop). Every question in the app goes here.
@MainActor
package func runSheet(_ a: NSAlert) async -> NSApplication.ModalResponse {
    guard let w = sheetWindow else { return a.runModal() }
    return await withCheckedContinuation { c in a.beginSheetModal(for: w) { c.resume(returning: $0) } }
}

/// A window of our own (a form) as a sheet on the front window, awaited; its buttons end it with
/// `sheetParent?.endSheet(_:returnCode:)`. `.abort` when there's no window to put it on.
@MainActor
package func runSheet(_ sheet: NSWindow) async -> NSApplication.ModalResponse {
    guard let w = sheetWindow else { return .abort }
    return await withCheckedContinuation { c in w.beginSheet(sheet) { c.resume(returning: $0) } }
}

/// A save panel as a sheet on the front window, awaited.
@MainActor
package func runSheet(_ p: NSSavePanel) async -> NSApplication.ModalResponse {
    guard let w = sheetWindow else { return p.runModal() }
    return await withCheckedContinuation { c in p.beginSheetModal(for: w) { c.resume(returning: $0) } }
}

/// Session-level agent actions shared by tabs and the sidebar.
@MainActor
package struct AgentActions {
    let app: AppModel
    package init(_ app: AppModel) { self.app = app }

    package func rename(_ sid: String) {
        let cur = app.session(sid)?.title ?? ""
        Task {
            guard let t = await prompt(String(localized: "Rename"), String(localized: "Leave empty to name it from the task automatically."),
                                       initial: cur) else { return }
            await app.call(SessionRename(id: sid, title: t))
        }
    }

    /// Same command in the same tab; resumes the conversation when the agent supports it.
    package func restart(_ sid: String) {
        Task {
            app.restarting.insert(sid); defer { app.restarting.remove(sid) }   // its tab is kept for the new one
            guard let s = await app.call(SessionRestart(id: sid)) else { return }
            app.sessions.removeAll { $0.id == sid }
            app.upsert(s)
            app.workbench.replace(session: sid, with: s.id, workspace: s.worktreeId)
        }
    }

    package func stop(_ ids: [String]) {
        let one = ids.count == 1
        let a = NSAlert(); a.messageText = one ? String(localized: "Stop this agent?") : String(localized: "Stop \(ids.count) agents?")
        a.informativeText = (one ? String(localized: "Its session ends") : String(localized: "Their sessions end"))
            + ". " + String(localized: "Conversations can be resumed from Session History.")
        // The button says what it stops (destructive: red).
        a.addButton(withTitle: one ? String(localized: "Stop Agent") : String(localized: "Stop \(ids.count) Agents")).hasDestructiveAction = true
        a.addButton(withTitle: String(localized: "Cancel"))
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn else { return }
            for id in ids { await app.call(SessionKill(id: id)) }
        }
    }

    /// "Hand Off to ▸ Codex": a new agent in the same workspace gets what this one did (its conversation, or the
    /// terminal's text) as a brief typed into its prompt, not sent. ⌥ hands over the full transcript instead of the latest part.
    package func handoffMenu(_ sid: String) -> NSMenu {
        let m = NSMenu()
        for a in app.catalog.installed(app.catalog.all) {
            m.add(a.name) { handoff(sid, to: a.id, full: false) }.image = app.catalog.icon(a.id)
            let full = m.add(String(localized: "\(a.name) — Full Transcript")) { handoff(sid, to: a.id, full: true) }
            full.isAlternate = true
            full.keyEquivalentModifierMask = .option
            full.image = app.catalog.icon(a.id)
        }
        return m
    }

    func handoff(_ sid: String, to agent: String, full: Bool) {
        Task {
            let p = SessionHandoff(id: sid, agent: agent, full: full,
                                   prompt: "Continue the task where the previous agent left off: check what's done, then finish it.",
                                   draft: true)
            guard let s = await app.call(p) else { return }
            app.upsert(s)
            app.workbench.open(TabURI.session(s.id), split: .right, workspace: s.worktreeId)
        }
    }

    package func copyContext(_ sid: String) {
        Task {
            guard let t = await app.call(SessionContext(id: sid)) else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string)
            Banner.show(String(localized: "Context copied"))
        }
    }
}

/// A one-field question (rename, go to line…).
@MainActor
package func prompt(_ title: String, _ info: String, initial: String = "") async -> String? {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = info
    let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); f.stringValue = initial
    a.accessoryView = f
    a.addButton(withTitle: String(localized: "OK"))
    a.addButton(withTitle: String(localized: "Cancel"))
    a.window.initialFirstResponder = f
    return await runSheet(a) == .alertFirstButtonReturn ? f.stringValue : nil
}
