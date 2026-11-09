import AppKit
import Core
import DesignKit
import KelpKit

/// Opening a database: the tab waits under "Connecting to …" (a wheel turning, past half a second), and if it can't
/// open, says why with the ways on (the password, the connection's form, another try).
extension DatabaseTab {

    /// The tab hidden under "Connecting to …" (said past half a second): nothing to press until it's open.
    func connecting() {
        whole.isHidden = true
        gate.show(nil)
        let db = database, name = address.name
        reading?.cancel()
        reading = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            let place = db.flatMap { DatabasePanelRows.place($0) }
            let asks =
                db?.passwordIn != nil
                ? String(localized: "macOS asks whether Kelp may read its password: look for its dialog.") : nil
            self?.loading.show(
                String(localized: "Connecting to \(name)…"),
                detail: [place, asks].compactMap { $0 }.joined(separator: "\n"))
        }
    }

    /// Why it didn't open, and the ways on: a password typed, the connection changed, another try.
    func failed(_ why: String) {
        whole.isHidden = true
        let noPassword = why.contains("no password") || why.contains("password authentication failed")
        var buttons: [NSButton] = []
        let edit = ClosureButton(
            title: noPassword ? String(localized: "Type the Password…") : String(localized: "Edit Connection…")
        ) { [weak self] in self?.editConnection() }
        edit.bezelStyle = .push
        if noPassword { edit.keyEquivalent = "\r" }
        let again = ClosureButton(title: String(localized: "Try Again")) { [weak self] in
            Task { await self?.loadTables() }
        }
        again.bezelStyle = .push
        if !noPassword { again.keyEquivalent = "\r" }
        buttons = [edit, again]
        gate.showError(String(localized: "Can’t Open \(address.name)"), text: why, buttons: buttons)
    }

    /// The connection's form (its password there); tried again once it closes.
    private func editConnection() {
        guard let db = database else { return }
        let library =
            app.latest(DatabasesEvent.self, address.worktree)?.library?.contains { $0.name == db.name } ?? false
        Task {
            await DatabaseSheet.run(app, worktreeId: address.worktree, editing: db, library: library)
            await loadTables()
        }
    }
}
