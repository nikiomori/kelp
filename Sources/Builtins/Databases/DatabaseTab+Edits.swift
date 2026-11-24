import AppKit
import Core
import DesignKit
import KelpKit

/// A table's edits: saved together in one transaction, shown as the SQL they'd run, or discarded. Closing the tab or
/// leaving the table with edits asks first, as an unsaved file does: Save, Cancel, Don't Save.
extension DatabaseTab {
    /// Asks what to do with the edits before they'd go; returns true to go on (saved, or the user dropped them).
    func settleEdits() async -> Bool {
        grid.commitTyping()
        guard isEdited else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Do you want to save the changes you made to “\(address.name)”?")
        alert.informativeText = String(localized: "\(grid.edits.count) changes you made aren’t saved.")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Don’t Save"))
        switch await runSheet(alert) {
        case .alertFirstButtonReturn: return await saveChanges()
        case .alertThirdButtonReturn:
            grid.discard()
            return true
        default: return false
        }
    }

    /// Drops every edit, after asking, because nothing brings them back.
    @objc func discardEdits() {
        let count = grid.edits.count
        Task {
            guard
                await confirm(
                    String(localized: "Discard all \(count) changes?"),
                    detail: String(localized: "This can’t be undone."),
                    action: String(localized: "Discard"), destructive: true)
            else { return }
            grid.discard()
        }
    }

    /// Shows what saving would run, before it runs.
    @objc func showEdits() {
        guard let statements = pending() else { return }
        let text = statements.joined(separator: ";\n") + ";"
        Task {
            if await confirm(
                String(localized: "\(statements.count) statements, in one transaction"), detail: text,
                action: String(localized: "Copy"), cancel: String(localized: "Close"))
            {
                copyText(text)
            }
        }
    }

    private func pending() -> [String]? {
        guard let name = mode.table, let table = current else { return nil }
        return grid.edits.statements(
            table: name, engine: engine, columns: grid.columns, primary: table.columns.filter(\.primary).map(\.name),
            rows: grid.rows, types: Dictionary(table.columns.map { ($0.name, $0.type) }) { first, _ in first })
    }

    @objc func saveEdits() { Task { await saveChanges() } }

    /// Saves all the edits in one transaction (`db.apply`). A production database asks first, in words. Returns true
    /// once they're saved.
    @discardableResult
    func saveChanges() async -> Bool {
        grid.commitTyping()   // a cell still being typed in is saved with the rest
        guard let name = mode.table, let statements = pending(), !statements.isEmpty else { return !isEdited }
        if database?.production == true {
            let alert = NSAlert()
            alert.messageText = String(localized: "Change \(address.name)? You marked it Production.")
            alert.informativeText = statements.joined(separator: ";\n") + ";"
            let change = alert.addButton(withTitle: String(localized: "Change Production"))
            change.hasDestructiveAction = true
            change.keyEquivalent = ""   // Return cancels, so a change to production takes a click
            alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\r"
            guard await runSheet(alert) == .alertFirstButtonReturn else { return false }
        }
        let (done, error) = await app.tryCall(
            DatabaseApply(worktreeId: address.worktree, database: address.name, statements: statements))
        guard let done else {
            Banner.show(String(localized: "Nothing saved: \(error ?? "")"), style: .error)
            return false
        }
        grid.edits.clear()
        await showTable(name)
        let saved = done.changed ?? 0, number = saved.formatted()
        status.stringValue +=
            " · " + (saved == 1 ? String(localized: "1 row saved") : String(localized: "\(number) rows saved"))
        // Each statement changes one row, so fewer changes mean a row wasn't where it was read (it changed
        // meanwhile).
        if let changed = done.changed, changed < statements.count {
            Banner.show(
                String(
                    localized:
                        "\(statements.count - changed) of the rows weren’t found as they were read: someone changed them meanwhile. Reloaded."
                ))
        }
        return true
    }
}

/// The tab's edits are unsaved work, as a file's are: quitting, and closing or archiving its workspace, ask about them.
extension DatabaseTab: SavableTab {
    @discardableResult func save() async -> Bool { await saveChanges() }
    func discard() { grid.discard() }
    var reopenURI: String? { uri }
}
