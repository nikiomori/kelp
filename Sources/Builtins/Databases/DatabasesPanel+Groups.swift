import AppKit
import Core
import DesignKit
import KelpKit

extension NSPasteboard.PasteboardType {
    /// One of All My Databases dragged in the Databases panel: its name.
    static let kelpDatabase = NSPasteboard.PasteboardType("app.kelp.database")
}

extension DatabaseInfo {
    /// Its group in All My Databases; nil: none (a blank one is none).
    var groupName: String? {
        let name = group?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? nil : name
    }
}

/// All My Databases' groups. One dragged onto a group goes into it, onto the section's title out of any, onto the
/// project's part is used here (a copy: it stays in All My Databases). A group lasts while it has a database; several
/// picked with ⌘ or ⇧ share one menu.
extension DatabasesPanel {
    enum DropTarget: Equatable { case group(String), noGroup, project }

    /// The groups in name order ("Dev 2" before "Dev 10"), each with its databases, and the ones in none.
    static func grouped(_ library: [DatabaseInfo]) -> (groups: [(String, [DatabaseInfo])], loose: [DatabaseInfo]) {
        let groups = Dictionary(grouping: library.filter { $0.groupName != nil }) { $0.groupName ?? "" }
        let named = groups.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map {
            ($0.key, $0.value)
        }
        return (named, library.filter { $0.groupName == nil })
    }

    var library: [DatabaseInfo] { app.latest(DatabasesEvent.self, workspace)?.library ?? [] }
    private var project: String { app.projectName(app.worktree(workspace)?.repoId) ?? "" }

    // MARK: Dragging

    /// One of All My Databases is no agent's yet: only this panel takes it. A project's, dropped on an agent's
    /// terminal, is its name and where to read it.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard case .database(let db, let library) = rows[row] else { return nil }
        let item = NSPasteboardItem()
        item.setString(library ? db.name : Self.mention(database: db.name), forType: library ? .kelpDatabase : .string)
        return item
    }

    func validateDatabases(_ info: any NSDraggingInfo, row: Int, op: NSTableView.DropOperation) -> NSDragOperation {
        let dbs = dragged(info)
        guard !dbs.isEmpty, let (target, lit) = dropTarget(row: row, op: op) else {
            springGroup = nil
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
        guard changes else { return [] }
        table.setDropRow(lit, dropOperation: .on)
        return target == .project ? .copy : .move
    }

    func acceptDatabases(_ info: any NSDraggingInfo, row: Int, op: NSTableView.DropOperation) -> Bool {
        springGroup = nil
        let dbs = dragged(info)
        guard !dbs.isEmpty, let (target, _) = dropTarget(row: row, op: op) else { return false }
        switch target {
        case .project: use(dbs)
        case .group(let name): move(dbs, to: name)
        case .noGroup: move(dbs, to: nil)
        }
        return true
    }

    private func dragged(_ info: any NSDraggingInfo) -> [DatabaseInfo] {
        let names = Set(info.draggingPasteboard.pasteboardItems?.compactMap { $0.string(forType: .kelpDatabase) } ?? [])
        return library.filter { names.contains($0.name) }
    }

    private var projectDatabases: [DatabaseInfo] { app.latest(DatabasesEvent.self, workspace)?.databases ?? [] }

    /// What the row under the pointer stands for, and the row that lights: a group's own row for any database in it,
    /// the section's title for one in none, the drop box (or the project's title) for the project's part. Between two
    /// rows, the one above says where.
    private func dropTarget(row: Int, op: NSTableView.DropOperation) -> (DropTarget, Int)? {
        var index = op == .on ? row : row - 1
        while rows.indices.contains(index), case .problem = rows[index] { index -= 1 }   // a line under its database
        guard rows.indices.contains(index) else { return nil }
        let heading = { (wanted: Heading) in
            self.rows.firstIndex { if case .heading(let h) = $0 { h == wanted } else { false } }
        }
        let libraryTitle = rows.firstIndex { if case .heading(.library) = $0 { true } else { false } }
        switch rows[index] {
        case .group(let name, _): return (.group(name), index)
        case .heading(.library): return (.noGroup, index)
        case .database(let db, library: true):
            if let name = db.groupName, let at = rows.firstIndex(where: { $0.isGroup(name) }) {
                return (.group(name), at)
            }
            return libraryTitle.map { (.noGroup, $0) }
        case .heading(.project), .hint, .database(_, library: false):
            let lit = rows.firstIndex { if case .hint = $0 { true } else { false } }
            return (lit ?? heading(.project(project))).map { (.project, $0) }
        default: return nil
        }
    }

    /// A folded group the drag rests on opens after a moment, as a folder does in Finder (validate is asked again and
    /// again while the pointer stays).
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
        Task { [weak self] in self?.reload() }   // not inside the table's own drag callback
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

    /// Used in this project, the ones it hasn't yet: its agents reach them from now on.
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
            let question = NSAlert(
                question: String(localized: "Forget \(dbs.count) databases?"),
                detail: String(
                    localized: "Their addresses and passwords leave Kelp. Projects that use them keep theirs."),
                action: String(localized: "Forget"))
            guard await runSheet(question) == .alertFirstButtonReturn else { return }
            for db in dbs {
                guard await app.call(DatabaseRemove(worktreeId: wid, name: db.name, library: true)) != nil else {
                    return
                }
            }
        }
    }

    // MARK: Menus

    /// The databases of All My Databases picked, when the clicked one is among them.
    func pickedLibrary(around row: Int) -> [DatabaseInfo] {
        guard table.selectedRowIndexes.contains(row) else { return [] }
        return table.selectedRowIndexes.compactMap { index in
            if case .database(let db, library: true) = rows[index] { db } else { nil }
        }
    }

    /// Several picked: what can be done to all of them at once.
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

    /// Move to Group ▸ (the groups there are, New Group…) and Remove from Group when one of them is in one.
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
        menu.setSubmenu(
            into, for: menu.addItem(withTitle: String(localized: "Move to Group"), action: nil, keyEquivalent: ""))
        if dbs.contains(where: { $0.groupName != nil }) {
            menu.add(String(localized: "Remove from Group")) { [weak self] in self?.move(dbs, to: nil) }
        }
    }

    /// A group's row: rename it, let its databases go, use them all here.
    func fillGroup(_ menu: NSMenu, _ name: String) {
        let members = library.filter { $0.groupName == name }
        menu.add(String(localized: "Rename…")) { [weak self] in
            Task {
                let named = await prompt(String(localized: "Rename Group"), "", initial: name)
                guard let new = named?.trimmingCharacters(in: .whitespaces), !new.isEmpty, new != name else { return }
                if self?.folded.remove(name) != nil { self?.folded.insert(new) }
                self?.move(members, to: new)
            }
        }
        menu.add(String(localized: "Ungroup")) { [weak self] in self?.move(members, to: nil) }
        menu.addItem(.separator())
        menu.add(String(localized: "Use All in \(project)")) { [weak self] in self?.use(members) }
    }
}

extension DatabasesPanel.Row {
    func isGroup(_ name: String) -> Bool { if case .group(name, _) = self { true } else { false } }
    /// One of All My Databases in a group: its row (and the line under it) sit one step in.
    var inGroup: Bool { if case .database(let db, library: true) = self { db.groupName != nil } else { false } }
}
