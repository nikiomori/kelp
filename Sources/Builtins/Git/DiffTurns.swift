import AppKit
import Core
import DesignKit
import KelpKit

/// The agent's turns, newest first, beside the "Agent’s Last Turn" source. The daemon keeps where each turn started
/// (`SessionTurns`), so any turn can be read again. Each turn is named by the prompt that started it.
extension DiffViewController {
    /// The id of the turn picked, or nil for the last one.
    var chosenTurn: String? {
        guard turnPop.indexOfSelectedItem > 0 else { return nil }
        return (turnPop.selectedItem?.representedObject as? SessionTurns.Mark)?.id
    }

    /// Reads the picker's turns again, keeping the one picked. The picker hides when the agent has no turns yet.
    func readTurns(_ session: String?) async {
        var marks: [SessionTurns.Mark] = []
        if let session { marks = await app.quiet(SessionTurns(id: session)) ?? [] }
        let picked = chosenTurn
        turnPop.removeAllItems()
        for (index, mark) in marks.enumerated() {
            let when = mark.at.formatted(date: .omitted, time: .shortened)
            let title = index == 0 ? String(localized: "Last Turn") : "“\(mark.prompt.prefix(48))” · \(when)"
            turnPop.addItem(withTitle: title)
            turnPop.lastItem?.representedObject = mark
            turnPop.lastItem?.toolTip = mark.prompt
        }
        if let picked, let index = marks.firstIndex(where: { $0.id == picked }) { turnPop.selectItem(at: index) }
        turnBar.isHidden = marks.isEmpty
    }

    /// A database's line in the sheet's list: "And shop.sqlite, as it was before the turn", with what the agent did
    /// to it under it, or why it can't go back.
    static func line(_ database: SessionTurnUndo.Database, afterFiles: Bool) -> String {
        if let cannot = database.cannot {
            return String(localized: "\(database.name) can't go back: \(cannot) The files still can.")
        }
        let first = afterFiles ? String(localized: "And \(database.name), as it was before the turn") : ""
        return ([first] + [database.detail].compactMap { $0 }).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func undoTurnButton() -> NSButton {
        let button = TextButton(String(localized: "Undo Turn…")) { [weak self] in self?.undoTurn() }
        button.toolTip = String(localized: "Put the files back as they were before this turn")
        return button
    }

    /// Shows what goes back first, in a sheet, then undoes the turn only if the folder is still as it was shown
    /// (`SessionTurnUndo`).
    private func undoTurn() {
        // The turn's own agent undoes it, not whichever agent has the focus now.
        guard let mark = turnPop.selectedItem?.representedObject as? SessionTurns.Mark else {
            NSSound.beep()
            return
        }
        let sid = mark.session, turn = mark.id
        Task { [self] in
            // On failure the banner says why not.
            guard let plan = await app.call(SessionTurnUndo(id: sid, turn: turn)) else { return }
            let databases = plan.databases ?? []
            guard !plan.files.isEmpty || databases.contains(where: { $0.cannot == nil }) else {
                status.stringValue =
                    databases.first.map { Self.line($0, afterFiles: false) }
                    ?? String(localized: "Nothing changed since that turn began")
                return
            }
            let shown = plan.files.prefix(12).joined(separator: "\n"), more = plan.files.count - 12
            let files = shown + (more > 0 ? "\n" + String(localized: "and \(more) more") : "")
            let detail =
                ([files] + databases.map { Self.line($0, afterFiles: !plan.files.isEmpty) }).filter { !$0.isEmpty }
                .joined(separator: "\n") + "\n\n"
                + String(
                    localized:
                        "Files the turn made go to the Trash; .env files stay as they are. Later turns' changes and your own edits in these files go too; Redo brings them back."
                )
            let names = databases.filter { $0.cannot == nil }.map(\.name).joined(separator: ", ")
            let title =
                plan.files.isEmpty
                ? String(localized: "Put \(names) back as it was before this turn?")
                : String(localized: "Put \(plan.files.count) files back as they were before this turn?")
            guard
                await confirm(title, detail: detail, action: String(localized: "Put Back"), destructive: true),
                let after = await app.call(
                    SessionTurnUndo(
                        id: sid, turn: turn, apply: true, state: plan.state,
                        databases: databases.filter { $0.cannot == nil }.map(\.name)))
            else { return }
            status.stringValue =
                plan.files.isEmpty
                ? String(localized: "Put \(names) back") : String(localized: "Put \(plan.files.count) files back")
            await load()
            let done =
                plan.files.isEmpty
                ? String(localized: "Put \(names) back as it was before the turn")
                : String(localized: "Put \(plan.files.count) files back as they were before the turn")
            Banner.show(
                done,
                action: (
                    String(localized: "Redo"),
                    { [weak self] in
                        Task {
                            guard let self,
                                await self.app.call(SessionTurnRedo(id: sid, turn: turn, state: after.state)) != nil
                            else { return }
                            self.status.stringValue = ""
                            await self.load()
                        }
                    }
                ), lasts: 60)
        }
    }
}
