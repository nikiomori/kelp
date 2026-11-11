// A database's menu, shared by its panel row and its tab: open, agents, production's guard.
import AppKit
import Core
import DesignKit
import KelpKit

/// A database's menu, in the panel and on its tab: open it, what agents may do, production, its address, edit, forget;
/// one of All My Projects is used in this project instead.
@MainActor
enum DatabaseMenu {
    /// `more` adds to the part about where it's used (All My Databases' groups).
    static func fill(
        _ menu: NSMenu, _ db: DatabaseInfo, app: AppModel, worktreeId: String, library: Bool = false,
        more: (NSMenu) -> Void = { _ in }
    ) {
        menu.add(String(localized: "Open")) {
            app.workbench.open(DatabaseURI(worktree: worktreeId, name: db.name).uri)
        }
        menu.addItem(.separator())
        if library {
            let project = app.projectName(app.worktree(worktreeId)?.repoId) ?? ""
            menu.add(String(localized: "Use in \(project)")) {
                Task { await app.call(DatabaseUse(worktreeId: worktreeId, name: db.name)) }
            }
            more(menu)
        } else {
            menu.setSubmenu(
                agents(db, app: app, worktreeId: worktreeId),
                for: menu.addItem(withTitle: String(localized: "Agents"), action: nil, keyEquivalent: ""))
            production(menu, db, app: app, worktreeId: worktreeId)
            // A copy to change on this branch without touching the project's (`db.copy`): files and a Postgres here.
            if !db.production, db.engine != .mysql, let branch = app.worktree(worktreeId)?.branch {
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
        menu.addItem(.separator())
        menu.add(String(localized: "Copy Address")) { copyText(db.address) }
        if !db.engine.isFile {   // another database of the same server: the form, filled in, under a new name
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
            // One used from All My Projects leaves this project only: it stays there, its password with it.
            let mine = app.latest(DatabasesEvent.self, worktreeId)?.library?.contains { $0.name == db.name } ?? false
            let project = app.projectName(app.worktree(worktreeId)?.repoId) ?? ""
            let title =
                !library && mine ? String(localized: "Remove from \(project)") : String(localized: "Forget")
            menu.add(title) {
                Task { await app.call(DatabaseRemove(worktreeId: worktreeId, name: db.name, library: library)) }
            }
        }
    }

    /// What agents may do, a choice each; the panel's access icon shows the same menu.
    static func agents(_ db: DatabaseInfo, app: AppModel, worktreeId: String) -> NSMenu {
        let agents = NSMenu()
        if db.production {   // what's picked waits until it's no longer production
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

    /// A line under a choice saying what it does (a tooltip before macOS 14.4).
    private static func explain(_ item: NSMenuItem, _ line: String) {
        if #available(macOS 14.4, *) { item.subtitle = line } else { item.toolTip = line }
    }

    /// Local, Development, Staging, Production. Leaving Production (agents get more than reading) is said first.
    private static func production(_ menu: NSMenu, _ db: DatabaseInfo, app: AppModel, worktreeId: String) {
        let stages = NSMenu()
        for stage in DatabaseInfo.Stage.allCases {
            let item = stages.add(DatabaseLook.title(stage)) {
                var changed = db
                changed.set(stage: stage)
                Task {
                    if db.production, stage != .production {
                        let alert = NSAlert()
                        alert.messageText = String(localized: "Let agents change \(db.name)?")
                        alert.informativeText = String(
                            localized:
                                "\(db.address) stops being production: agents get what Agents says, \(DatabaseLook.title(changed.access)), and their changes reach it."
                        )
                        alert.addButton(withTitle: String(localized: "Make It \(DatabaseLook.title(stage))"))
                        alert.addButton(withTitle: String(localized: "Cancel"))
                        guard await runSheet(alert) == .alertFirstButtonReturn else { return }
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
        menu.setSubmenu(
            stages, for: menu.addItem(withTitle: String(localized: "Environment"), action: nil, keyEquivalent: ""))
    }
}
