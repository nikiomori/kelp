import AppKit
import Core
import DesignKit
import KelpKit

/// What a click on a row does (open a database or a run, fold a section or a group), and what the row's menu holds.
extension DatabasesPanel {
    // MARK: Clicks

    @objc func clicked() {
        let index = table.actedRow
        guard rows.indices.contains(index) else { return }
        let wid = workspace
        switch rows[index] {
        case .heading(.library): libraryOpen.toggle()
        case .heading(.activity): activityOpen.toggle()
        case .heading: return
        case .group(let name, _):
            if folded.remove(name) == nil { folded.insert(name) }
        case .database(let db, _):
            // ⌘ and ⇧ pick several databases (to drag, or for the menu); a plain click opens the database.
            if !NSEvent.modifierFlags.isDisjoint(with: [.command, .shift]) { return }
            app.workbench.open(DatabaseURI(worktree: wid, name: db.name).uri)
            return
        case .asks(let run), .run(let run):
            app.workbench.open(DatabaseURI(worktree: wid, name: run.database, run: run.id).uri)
            return
        case .use: return showUseMenu(at: index)
        case .problem, .project: return
        }
        turning = rows[index].key
        table.crossfade(Motion.base)   // a fold's rows fade out or in, because there are too many to move one by one
        reload()
    }

    func answer(_ run: DatabaseRun, allow: Bool) {
        guard let sid = run.session else { return }
        Notifications.answer(app, sid, allow ? "allow" : "deny", question: app.session(sid)?.summary)
    }

    func start(_ db: DatabaseInfo) {
        let wid = workspace
        health[db.name] = DatabaseHealth(name: db.name, state: .unknown, reason: nil)
        reload()
        Task {
            _ = await app.call(DatabaseStart(worktreeId: wid, name: db.name))
            checkedFor = []
            reload()
        }
    }

    /// Uses one of All My Databases in this project, so the project's agents reach it from now on.
    func use(_ db: DatabaseInfo) {
        let wid = workspace
        Task { await app.call(DatabaseUse(worktreeId: wid, name: db.name)) }
    }

    func filter(_ session: String?) {
        only = session
        reload()
    }

    // MARK: Menu

    func menuDidClose(_ menu: NSMenu) { if colorPreview != nil { colorPreview = nil } }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let app = app, wid = workspace
        guard rows.indices.contains(table.clickedRow) else {
            menu.add(String(localized: "Add Database…")) { [weak self] in self?.addDatabase() }
            return
        }
        switch rows[table.clickedRow] {
        case .heading(.activity):
            let agents = Set((app.latest(DatabasesEvent.self, wid)?.runs ?? []).compactMap(\.session))
            menu.add(String(localized: "Everyone’s")) { [weak self] in self?.filter(nil) }.state =
                only == nil ? .on : .off
            for sid in agents.sorted() {
                guard let agent = app.session(sid) else { continue }
                menu.add(agent.title.isEmpty ? app.catalog.name(agent.agent) : agent.title) { [weak self] in
                    self?.filter(sid)
                }
                .state = only == sid ? .on : .off
            }
        case .heading: menu.add(String(localized: "Add Database…")) { [weak self] in self?.addDatabase() }
        case .database(let db, let library):
            let picked = pickedLibrary(around: table.clickedRow)
            if picked.count > 1 { return fillMany(menu, picked) }
            DatabaseMenu.fill(menu, db, app: app, worktreeId: wid, library: library) { [weak self] in
                if library { self?.addGroupItems($0, [db]) }
                self?.addColorItem($0, db.name, group: false)
            }
        case .group(let name, _): fillGroup(menu, name)
        case .asks(let run), .run(let run):
            menu.add(String(localized: "Show Rows")) {
                app.workbench.open(DatabaseURI(worktree: wid, name: run.database, run: run.id).uri)
            }
            if let session = run.session, app.session(session) != nil {
                menu.add(String(localized: "Show the Chat That Ran It")) { app.workbench.focus(session: session) }
            }
            menu.addItem(.separator())
            menu.add(String(localized: "Copy SQL")) { copyText(run.sql) }
        case .problem: break
        case .project, .use: menu.add(String(localized: "Add Database…")) { [weak self] in self?.addDatabase() }
        }
    }
}
