import AppKit
import Core
import DesignKit
import KelpKit

extension NSPasteboard.PasteboardType {
    /// One of All My Databases dragged in the Databases panel. The pasteboard holds its name.
    static let kelpDatabase = NSPasteboard.PasteboardType("app.kelp.database")
    /// A group of All My Databases dragged, holding the group's name. Only the project's part of the panel takes
    /// it, with all the group's databases at once.
    static let kelpDatabaseGroup = NSPasteboard.PasteboardType("app.kelp.database-group")
}

extension DatabaseInfo {
    /// The database's group in All My Databases, or nil for none (a blank name counts as none).
    var groupName: String? {
        let name = group?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? nil : name
    }
}

/// The groups of All My Databases. A database dragged onto a group goes into it, and one dropped on the section's
/// title leaves every group. A database dropped on the project's part is used here, as a copy, so it stays in All My
/// Databases. A group dragged there brings all of its databases. A group lasts while it has a database. Several
/// databases picked with ⌘ or ⇧ share one menu.
extension DatabasesPanel {
    enum DropTarget: Equatable { case group(String), noGroup, project }

    /// The groups in name order ("Dev 2" before "Dev 10"), each with its databases, and the databases in none.
    static func grouped(_ library: [DatabaseInfo]) -> (groups: [(String, [DatabaseInfo])], loose: [DatabaseInfo]) {
        let groups = Dictionary(grouping: library.filter { $0.groupName != nil }) { $0.groupName ?? "" }
        let named = groups.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map {
            ($0.key, $0.value)
        }
        return (named, library.filter { $0.groupName == nil })
    }

    var library: [DatabaseInfo] { listed?.library ?? [] }
    private var project: String { app.projectName(app.worktree(workspace)?.repoId) ?? "" }

    // MARK: Dragging

    /// A database from All My Databases isn't any agent's yet, so only this panel accepts it. A project's database
    /// dropped on an agent's terminal becomes its name and how to read it.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        let item = NSPasteboardItem()
        if case .group(let name, _) = rows[row] {
            item.setString(name, forType: .kelpDatabaseGroup)
            return item
        }
        guard case .database(let db, let library) = rows[row] else { return nil }
        item.setString(library ? db.name : Self.mention(database: db.name), forType: library ? .kelpDatabase : .string)
        return item
    }

    func validateDatabases(_ info: any NSDraggingInfo, row: Int, op: NSTableView.DropOperation) -> NSDragOperation {
        let dbs = dragged(info)
        guard !dbs.isEmpty, let (target, lit) = dropTarget(row: row, op: op), target == .project || !isGroup(info)
        else {
            springGroup = nil
            dropOnProject = false
            return []
        }
        springOpen(target)
        let changes =
            switch target {
            case .project:
                dbs.contains { db in !projectDatabases.contains { $0.name == db.name } }
            case .group(let name): dbs.contains { $0.groupName != name }
            case .noGroup: dbs.contains { $0.groupName != nil }
            }
        dropOnProject = target == .project && changes
        guard changes else { return [] }
        // The project's card lights up as a whole (dropOnProject), because the table's own outline round one row
        // would say less.
        table.draggingDestinationFeedbackStyle = target == .project ? .none : .regular
        table.setDropRow(lit, dropOperation: .on)
        return target == .project ? .copy : .move
    }

    func acceptDatabases(_ info: any NSDraggingInfo, row: Int, op: NSTableView.DropOperation) -> Bool {
        springGroup = nil
        dropOnProject = false
        let dbs = dragged(info)
        guard !dbs.isEmpty, let (target, _) = dropTarget(row: row, op: op), target == .project || !isGroup(info)
        else { return false }
        switch target {
        case .project: use(dbs)
        case .group(let name): move(dbs, to: name)
        case .noGroup: move(dbs, to: nil)
        }
        return true
    }

    private func dragged(_ info: any NSDraggingInfo) -> [DatabaseInfo] {
        let items = info.draggingPasteboard.pasteboardItems ?? []
        let names = Set(items.compactMap { $0.string(forType: .kelpDatabase) })
        let groups = Set(items.compactMap { $0.string(forType: .kelpDatabaseGroup) })
        return library.filter { names.contains($0.name) || $0.groupName.map(groups.contains) == true }
    }

    private func isGroup(_ info: any NSDraggingInfo) -> Bool {
        info.draggingPasteboard.availableType(from: [.kelpDatabaseGroup]) != nil
    }

    private var projectDatabases: [DatabaseInfo] { listed?.databases ?? [] }
    /// The names of the project's databases. One of All My Databases whose name is among them is used here.
    var projectNames: Set<String> { Set(projectDatabases.map(\.name)) }

    /// What the row under the pointer stands for, and which row lights up. Any database in a group lights the
    /// group's own row, a database in no group lights the section's title, and the project's part lights the
    /// project's card. Between two rows, the row above decides.
    private func dropTarget(row: Int, op: NSTableView.DropOperation) -> (DropTarget, Int)? {
        var index = op == .on ? row : row - 1
        while rows.indices.contains(index), case .problem = rows[index] { index -= 1 }   // up past problem lines
        guard rows.indices.contains(index) else { return nil }
        let libraryTitle = rows.firstIndex { if case .heading(.library) = $0 { true } else { false } }
        switch rows[index] {
        case .group(let name, _): return (.group(name), index)
        case .heading(.library): return (.noGroup, index)
        case .database(let db, library: true):
            if let name = db.groupName, let at = rows.firstIndex(where: { $0.isGroup(name) }) {
                return (.group(name), at)
            }
            return libraryTitle.map { (.noGroup, $0) }
        case .project, .use, .database(_, library: false): return (.project, index)
        default: return nil
        }
    }

    /// A folded group the drag rests on opens after a moment, as a folder does in Finder. This works because AppKit
    /// asks validate again and again while the pointer stays.
    private func springOpen(_ target: DropTarget) {
        guard case .group(let name) = target, folded.contains(name) else {
            springGroup = nil
            return
        }
        guard let spring = springGroup, spring.name == name else {
            springGroup = (name, Date())
            return
        }
        guard Date().timeIntervalSince(spring.since) > Motion.hoverOpen else { return }
        springGroup = nil
        folded.remove(name)
        Task { [weak self] in self?.reload() }   // later, not inside the table's own drag callback
    }

    // MARK: Changes

    func move(_ dbs: [DatabaseInfo], to group: String?) {
        let wid = workspace, app = app
        Task {
            for var db in dbs where db.groupName != group {
                db.group = group
                guard await app.call(DatabaseSave(worktreeId: wid, database: db, library: true)) != nil else { return }
            }
        }
    }

    /// Use a Database…: a menu of All My Databases by group, with a check on each one used here. Picking a database
    /// uses it here, or lets it go.
    func showUseMenu(at row: Int) {
        let menu = NSMenu(), here = projectNames, (groups, loose) = Self.grouped(library)
        for (name, members) in groups {
            menu.addItem(withTitle: name, action: nil, keyEquivalent: "").isEnabled = false
            for db in members { addUseItem(menu, db, used: here.contains(db.name), indent: 1) }
        }
        if !groups.isEmpty, !loose.isEmpty { menu.addItem(.separator()) }
        for db in loose { addUseItem(menu, db, used: here.contains(db.name), indent: 0) }
        let cell = table.rect(ofRow: row)
        menu.popUp(positioning: nil, at: NSPoint(x: cell.minX + DatabasePanelRows.inCard, y: cell.maxY), in: table)
    }

    private func addUseItem(_ menu: NSMenu, _ db: DatabaseInfo, used: Bool, indent: Int) {
        let wid = workspace, app = app
        let item = menu.add(DatabasePanelRows.shownName(db)) {
            Task {
                if used {
                    await app.call(DatabaseRemove(worktreeId: wid, name: db.name, library: false))
                } else {
                    await app.call(DatabaseUse(worktreeId: wid, name: db.name))
                }
            }
        }
        item.state = used ? .on : .off
        item.indentationLevel = indent
        if #available(macOS 14.4, *) { item.subtitle = DatabasePanelRows.place(db) }
    }

    /// Uses in this project the databases it doesn't use yet, so its agents reach them from now on.
    func use(_ dbs: [DatabaseInfo]) {
        let wid = workspace, app = app, here = Set(projectDatabases.map(\.name))
        Task {
            for db in dbs where !here.contains(db.name) {
                guard await app.call(DatabaseUse(worktreeId: wid, name: db.name)) != nil else { return }
            }
        }
    }

    private func newGroup(_ dbs: [DatabaseInfo]) {
        Task {
            let named = await prompt(
                String(localized: "New Group"), String(localized: "A group in All My Databases for these databases."))
            guard let name = named?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
            move(dbs, to: name)
        }
    }

    private func forget(_ dbs: [DatabaseInfo]) {
        let wid = workspace, app = app
        Task {
            guard
                await confirm(
                    String(localized: "Forget \(dbs.count) databases?"),
                    detail: String(
                        localized: "Their addresses and passwords leave Kelp. Projects that use them keep theirs."),
                    action: String(localized: "Forget"))
            else { return }
            for db in dbs {
                guard await app.call(DatabaseRemove(worktreeId: wid, name: db.name, library: true)) != nil else {
                    return
                }
            }
        }
    }

    // MARK: Menus

    /// The picked databases of All My Databases, when the clicked one is among them.
    func pickedLibrary(around row: Int) -> [DatabaseInfo] {
        guard table.selectedRowIndexes.contains(row) else { return [] }
        return table.selectedRowIndexes.compactMap { index in
            if case .database(let db, library: true) = rows[index] { db } else { nil }
        }
    }

    /// The menu for several picked databases: what can be done to all of them at once.
    func fillMany(_ menu: NSMenu, _ dbs: [DatabaseInfo]) {
        let app = app, wid = workspace
        menu.add(String(localized: "Open \(dbs.count) Databases")) {
            for db in dbs { app.workbench.open(DatabaseURI(worktree: wid, name: db.name).uri) }
        }
        menu.addItem(.separator())
        menu.add(String(localized: "New Group from Selection…")) { [weak self] in self?.newGroup(dbs) }
        addGroupItems(menu, dbs)
        menu.addItem(.separator())
        menu.add(String(localized: "Use in \(project)")) { [weak self] in self?.use(dbs) }
        menu.addItem(.separator())
        menu.add(String(localized: "Copy Addresses")) { copyText(dbs.map(\.address).joined(separator: "\n")) }
        menu.add(String(localized: "Forget \(dbs.count) Databases…")) { [weak self] in self?.forget(dbs) }
    }

    /// Adds Move to Group ▸ (the groups there are, and New Group…), and Remove from Group when any of the databases
    /// is in one.
    func addGroupItems(_ menu: NSMenu, _ dbs: [DatabaseInfo]) {
        let groups = Set(library.compactMap(\.groupName)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        let into = NSMenu()
        for name in groups {
            into.add(name) { [weak self] in self?.move(dbs, to: name) }.state =
                dbs.allSatisfy { $0.groupName == name } ? .on : .off
        }
        if !groups.isEmpty { into.addItem(.separator()) }
        into.add(String(localized: "New Group…")) { [weak self] in self?.newGroup(dbs) }
        menu.add(String(localized: "Move to Group"), submenu: into)
        if dbs.contains(where: { $0.groupName != nil }) {
            menu.add(String(localized: "Remove from Group")) { [weak self] in self?.move(dbs, to: nil) }
        }
    }

    /// The menu on a group's row: rename it, let its databases go, or use them all here.
    func fillGroup(_ menu: NSMenu, _ name: String) {
        let members = library.filter { $0.groupName == name }
        menu.add(String(localized: "Rename…")) { [weak self] in
            Task {
                let named = await prompt(String(localized: "Rename Group"), "", initial: name)
                guard let new = named?.trimmingCharacters(in: .whitespaces), !new.isEmpty, new != name else { return }
                if self?.folded.remove(name) != nil { self?.folded.insert(new) }
                if let color = self?.color(of: name, group: true) {
                    self?.setColor(nil, of: name, group: true)
                    self?.setColor(color, of: new, group: true)
                }
                self?.move(members, to: new)
            }
        }
        menu.add(String(localized: "Ungroup")) { [weak self] in
            self?.setColor(nil, of: name, group: true)
            self?.move(members, to: nil)
        }
        addColorItem(menu, name, group: true)
        menu.addItem(.separator())
        menu.add(String(localized: "Use All in \(project)")) { [weak self] in self?.use(members) }
    }

    // MARK: Colors

    /// The colours picked in a row's menu, as for a project in the sidebar. Databases and groups each have their
    /// own, by name, kept in UIState.
    private static func colorsKey(group: Bool) -> String { group ? "databases.groupColors" : "databases.colors" }

    /// The colour of a database or group, or the one previewed under the pointer in its menu.
    func color(of name: String, group: Bool) -> ProjectColor? {
        if let preview = colorPreview, preview.name == name, preview.group == group { return preview.color }
        return ProjectColor.read(app.uiState[Self.colorsKey(group: group)])[name]
    }

    func setColor(_ color: ProjectColor?, of name: String, group: Bool) {
        var colors = ProjectColor.read(app.uiState[Self.colorsKey(group: group)])
        colors[name] = color
        app.uiState[Self.colorsKey(group: group)] = ProjectColor.value(colors)
        table.reloadData()
    }

    func addColorItem(_ menu: NSMenu, _ name: String, group: Bool) {
        let chosen = ProjectColor.read(app.uiState[Self.colorsKey(group: group)])[name]
        menu.addColor(
            chosen: chosen, previewing: { [weak self] in self?.colorPreview = (name, group, $0) },
            left: { [weak self] in self?.colorPreview = nil }
        ) { [weak self] in
            self?.colorPreview = nil
            self?.setColor($0, of: name, group: group)
        }
    }
}

extension DatabasesPanel.Row {
    func isGroup(_ name: String) -> Bool { if case .group(name, _) = self { true } else { false } }
}

/// The Databases panel's list. It says when a drag leaves it, so the project's card stops lighting up.
final class DropTable: NSTableView {
    var dragLeft: () -> Void = {}
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        dragLeft()
    }
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        super.draggingEnded(sender)
        dragLeft()
    }
}
