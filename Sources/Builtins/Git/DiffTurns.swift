import AppKit
import Core
import KelpKit

/// The agent's turns, newest first, beside the "Agent's Last Turn" source: each one's start is kept by the daemon
/// (`SessionTurns`), so any of them can be read again, named by the prompt that started it.
extension DiffViewController {
    /// The turn picked, nil for the last one.
    var chosenTurn: String? {
        guard turnPop.indexOfSelectedItem > 0 else { return nil }
        return (turnPop.selectedItem?.representedObject as? SessionTurns.Mark)?.id
    }

    /// The picker's turns read again, the one picked kept; hidden with no history (a remote project, none yet).
    func readTurns(_ session: String?) async {
        var marks: [SessionTurns.Mark] = []
        if let session { marks = await app.quiet(SessionTurns(id: session)) ?? [] }
        let picked = chosenTurn
        turnPop.removeAllItems()
        for (i, m) in marks.enumerated() {
            let when = m.at.formatted(date: .omitted, time: .shortened)
            let title = i == 0 ? String(localized: "Last Turn") : "“\(m.prompt.prefix(48))” · \(when)"
            turnPop.addItem(withTitle: title)
            turnPop.lastItem?.representedObject = m
            turnPop.lastItem?.toolTip = m.prompt
        }
        if let picked, let i = marks.firstIndex(where: { $0.id == picked }) { turnPop.selectItem(at: i) }
        turnBar.isHidden = marks.isEmpty
    }

    func undoTurnButton() -> NSButton {
        let b = ClosureButton(title: String(localized: "Undo Turn…")) { [weak self] in self?.undoTurn() }
        b.bezelStyle = .push
        b.controlSize = .small
        b.toolTip = String(localized: "Put the files back as they were before this turn")
        return b
    }

    /// What goes back first, in a sheet; then only if the folder is still as it was shown (`SessionTurnUndo`).
    private func undoTurn() {
        // The turn's own agent, not whichever has the focus now.
        guard let mark = turnPop.selectedItem?.representedObject as? SessionTurns.Mark else { NSSound.beep(); return }
        let sid = mark.session, turn = mark.id
        Task { [self] in
            guard let plan = await app.call(SessionTurnUndo(id: sid, turn: turn)) else { return }   // the banner says why not
            guard !plan.files.isEmpty else { status.stringValue = String(localized: "Nothing changed since that turn began"); return }
            let a = NSAlert()
            a.messageText = String(localized: "Put \(plan.files.count) files back as they were before this turn?")
            let shown = plan.files.prefix(12).joined(separator: "\n"), more = plan.files.count - 12
            a.informativeText = shown + (more > 0 ? "\n" + String(localized: "and \(more) more") : "") + "\n\n"
                + String(localized: "Files the turn made go to the Trash; .env files stay as they are. Later turns' changes and your own edits in these files go too; Redo brings them back.")
            a.addButton(withTitle: String(localized: "Put Back")).hasDestructiveAction = true
            a.addButton(withTitle: String(localized: "Cancel"))
            guard await runSheet(a) == .alertFirstButtonReturn,
                  let after = await app.call(SessionTurnUndo(id: sid, turn: turn, apply: true, state: plan.state)) else { return }
            status.stringValue = String(localized: "Put \(plan.files.count) files back")
            await load()
            let done = String(localized: "Put \(plan.files.count) files back as they were before the turn")
            Banner.show(done, action: (String(localized: "Redo"), { [weak self] in
                Task {
                    guard let self, await self.app.call(SessionTurnRedo(id: sid, turn: turn, state: after.state)) != nil else { return }
                    self.status.stringValue = ""
                    await self.load()
                }
            }), lasts: 60)
        }
    }
}
