// The menu of a database, shared by its panel row and its tab: open, agents, and production's guard.
import AppKit
import Core
import DesignKit
import KelpKit

/// The menu of a database, in the panel and on its tab: open it, what agents may do, production, its address, edit
/// and forget. A database from All My Projects can be used in this project instead. A branch's copy can be made again
/// or deleted.
@MainActor
enum DatabaseMenu {
    /// `more` adds items to the part about where the database is used (All My Databases' groups) and how it looks (its
    /// colour).
    static func fill(
        _ menu: NSMenu, _ db: DatabaseInfo, app: AppModel, worktreeId: String, library: Bool = false,
        more: (NSMenu) -> Void = { _ in }
    ) {
        menu.add(String(localized: "Open")) {
            app.workbench.open(DatabaseURI(worktree: worktreeId, name: db.name).uri)
        }
        menu.addItem(.separator())
        if let copy = db.copy {   // a branch's own copy has no address to edit and nothing to forget but itself
            menu.add(String(localized: "Agents"), submenu: agents(db, app: app, worktreeId: worktreeId))
            copyItems(menu, db, copy, app: app, worktreeId: worktreeId)
            more(menu)
            menu.addItem(.separator())
            menu.add(String(localized: "Copy Address")) { copyText(db.address) }
            return
        }
        let copied =
            app.latest(DatabasesEvent.self, worktreeId)?.databases.contains {
                $0.copy?.of == db.name && $0.name != db.name
            } ?? false
        if library {
            let project = app.projectName(app.worktree(worktreeId)?.repoId) ?? ""
            menu.add(String(localized: "Use in \(project)")) {
                Task { await app.call(DatabaseUse(worktreeId: worktreeId, name: db.name)) }
            }
        } else {
            menu.add(String(localized: "Agents"), submenu: agents(db, app: app, worktreeId: worktreeId))
            production(menu, db, app: app, worktreeId: worktreeId)
            // Offers a copy to change on this branch without touching the project's database (`db.copy`), for a
            // file database or a Postgres here.
            if !db.production, db.engine != .mysql, !copied, let branch = app.worktree(worktreeId)?.branch {
                menu.add(String(localized: "Copy for \(branch)")) {
                    Task {
                        guard let copy = await app.call(DatabaseCopy(worktreeId: worktreeId, database: db.name)) else {
                            return
                        }
                        Banner.show(String(localized: "\(copy.name) is \(branch)'s copy of \(db.name)."))
                        app.workbench.open(DatabaseURI(worktree: worktreeId, name: copy.name).uri)
                    }
                }
            }
        }
        more(menu)
        menu.addItem(.separator())
        menu.add(String(localized: "Copy Address")) { copyText(db.address) }
        if !db.engine.isFile {   // another database on the same server opens the form filled in, under a new name
            menu.add(String(localized: "Duplicate…")) {
                var copy = db
                copy.name = ""
                copy.source = nil
                Task { await DatabaseSheet.run(app, worktreeId: worktreeId, adding: DatabaseAddress(database: copy)) }
            }
        }
        if db.source == nil {
            menu.add(String(localized: "Edit…")) {
                Task { await DatabaseSheet.run(app, worktreeId: worktreeId, editing: db, library: library) }
            }
            // A database used from All My Projects leaves only this project. It stays in All My Projects, with its
            // password.
            let mine = app.latest(DatabasesEvent.self, worktreeId)?.library?.contains { $0.name == db.name } ?? false
            let project = app.projectName(app.worktree(worktreeId)?.repoId) ?? ""
            let title =
                !library && mine ? String(localized: "Remove from \(project)") : String(localized: "Forget")
            menu.add(title) {
                Task { await app.call(DatabaseRemove(worktreeId: worktreeId, name: db.name, library: library)) }
            }
        }
    }

    /// The items for a branch's copy: make it again from the database it copies, or delete it. Each asks first,
    /// saying what will be lost.
    private static func copyItems(
        _ menu: NSMenu, _ db: DatabaseInfo, _ copy: BranchCopy, app: AppModel, worktreeId: String
    ) {
        let branch = app.worktree(worktreeId)?.branch ?? ""
        menu.add(String(localized: "Reset from \(copy.of)…")) {
            Task {
                guard
                    await confirm(
                        String(localized: "Make \(branch)’s copy of \(copy.of) again?"),
                        detail: String(localized: "What’s in the copy now is replaced with \(copy.of) as it is."),
                        action: String(localized: "Reset"), destructive: true),
                    await app.call(DatabaseCopyRemove(worktreeId: worktreeId, database: db.name)) != nil
                else { return }
                await app.call(DatabaseCopy(worktreeId: worktreeId, database: copy.of))
            }
        }
        menu.add(String(localized: "Delete Copy…")) {
            Task {
                guard
                    await confirm(
                        String(localized: "Delete \(branch)’s copy of \(copy.of)?"),
                        detail: String(localized: "What’s in the copy is gone. \(copy.of) itself stays as it is."),
                        action: String(localized: "Delete Copy"), destructive: true)
                else { return }
                await app.call(DatabaseCopyRemove(worktreeId: worktreeId, database: db.name))
            }
        }
    }

    /// The menu of what agents may do, one choice each. The access icon in the panel shows the same menu.
    static func agents(_ db: DatabaseInfo, app: AppModel, worktreeId: String) -> NSMenu {
        let agents = NSMenu()
        if db.production {   // the pick waits until the database is no longer production
            let note = agents.addItem(
                withTitle: String(localized: "Production: agents only read it"), action: nil, keyEquivalent: "")
            note.isEnabled = false
            agents.addItem(.separator())
        }
        for access in DatabaseInfo.Access.allCases {
            let item = agents.add(DatabaseLook.title(access)) {
                var changed = db
                changed.access = access
                Task { await app.call(DatabaseSave(worktreeId: worktreeId, database: changed)) }
            }
            item.state = db.access == access ? .on : .off
            item.image = .symbol(DatabaseLook.accessSymbol(access))
            Self.explain(item, DatabaseLook.meaning(access))
        }
        return agents
    }

    /// Puts a line under a choice saying what it does (a tooltip before macOS 14.4).
    private static func explain(_ item: NSMenuItem, _ line: String) {
        if #available(macOS 14.4, *) { item.subtitle = line } else { item.toolTip = line }
    }

    /// The environment items: Local, Development, Staging, Production. Leaving Production gives agents more than
    /// reading, so the menu says so first.
    private static func production(_ menu: NSMenu, _ db: DatabaseInfo, app: AppModel, worktreeId: String) {
        let stages = NSMenu()
        for stage in DatabaseInfo.Stage.allCases {
            let item = stages.add(DatabaseLook.title(stage)) {
                var changed = db
                changed.set(stage: stage)
                Task {
                    if db.production, stage != .production {
                        let detail = String(
                            localized:
                                "\(db.address) stops being production: agents get what Agents says, \(DatabaseLook.title(changed.access)), and their changes reach it."
                        )
                        guard
                            await confirm(
                                String(localized: "Let agents change \(db.name)?"), detail: detail,
                                action: String(localized: "Make It \(DatabaseLook.title(stage))"))
                        else { return }
                    }
                    await app.call(DatabaseSave(worktreeId: worktreeId, database: changed))
                }
            }
            item.state = db.stage == stage ? .on : .off
            Self.explain(item, DatabaseLook.meaning(stage))
            item.image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
                DatabaseLook.color(stage).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
                return true
            }
        }
        menu.add(String(localized: "Environment"), submenu: stages)
    }
}
