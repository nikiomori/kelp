import AppKit
import Core
import DesignKit
import KelpKit

/// Opening a database. The tab waits under "Connecting to …" (with a wheel that turns past half a second). If the
/// database can't open, the tab says why and offers the ways on: the password, the connection's form, another try.
extension DatabaseTab {

    /// Hides the tab under "Connecting to …", so nothing can be pressed until it's open. A database elsewhere takes more
    /// than a moment to answer, so its wait shows at once; one on this Mac shows it only past a second.
    func connecting() {
        whole.isHidden = true
        gate.show(nil)
        let db = database, name = address.name
        let elsewhere = db.map {
            !$0.engine.isFile && ($0.ssh != nil || $0.host.map { !DatabaseInfo.isLocal($0) } == true)
        }
        reading?.cancel()
        reading = Task { [weak self] in
            if elsewhere != true { do { try await Task.sleep(for: .seconds(1)) } catch { return } }
            let place = db.flatMap { DatabasePanelRows.place($0) }
            let asks =
                db?.passwordIn != nil
                ? String(localized: "macOS asks whether Kelp may read its password: look for its dialog.") : nil
            self?.loading.show(
                String(localized: "Connecting to \(name)…"),
                detail: [place, asks].compactMap { $0 }.joined(separator: "\n"))
        }
    }

    /// Says why the database didn't open, and offers the ways on: type a password, change the connection, try again.
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

    /// Opens the connection's form, where its password is, and tries again once the form closes.
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
