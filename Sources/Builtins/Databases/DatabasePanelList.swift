import Core

/// The Databases panel's rows in their order, from what the daemon listed and what the user folded or typed: an
/// agent's questions, the project's card with its databases (a branch's copy under the database it's of), All My
/// Databases by group, then what agents ran. A database is found by its name, address, environment or group.
@MainActor
struct DatabasePanelList {
    var databases: [DatabaseInfo] = [], library: [DatabaseInfo] = [], runs: [DatabaseRun] = []
    /// What the find field holds, trimmed and lowercased.
    var find = ""
    var libraryOpen = true, activityOpen = true
    /// Activity of one agent's session only; nil: everyone's.
    var only: String?
    var folded: Set<String> = []
    var health: [String: DatabaseHealth] = [:], libraryHealth: [String: DatabaseHealth] = [:]

    var rows: [DatabasesPanel.Row] {
        var list: [DatabasesPanel.Row] = []
        let asking = runs.filter { $0.state == .asks }
        if !asking.isEmpty { list += [.heading(.asks)] + asking.map(DatabasesPanel.Row.asks) }
        // The project's card even empty: All My Databases under it alone read as this project's.
        if !databases.isEmpty || !library.isEmpty {
            list.append(.project(count: databases.count))
            let under = databases.filter { copy in DatabasesPanel.nested(copy, among: databases) }
            for db in databases where !under.contains(db) {
                list += rows(of: db, library: false)
                for copy in under where copy.copy?.of == db.name { list += rows(of: copy, library: false) }
            }
            if !library.isEmpty { list.append(.use(empty: databases.isEmpty)) }
        }
        if !library.isEmpty {
            list.append(.heading(.library(library.count)))
            if libraryOpen || !find.isEmpty { list += libraryRows() }
        }
        // The user's own reads (browsing tables in a tab) aren't news here; what agents ran and any change are.
        let ran = runs.filter { $0.state != .asks && ($0.session != nil || $0.changed != nil) }
            .filter { only == nil || $0.session == only }.prefix(30)
        if !ran.isEmpty, find.isEmpty {
            list.append(.heading(.activity(ran.count)))
            if activityOpen { list += ran.map(DatabasesPanel.Row.run) }
        }
        return list
    }

    /// The groups by name, each with its databases (all of them while finding: a group's name finds them too), then
    /// the ones in none.
    private func libraryRows() -> [DatabasesPanel.Row] {
        let (groups, loose) = DatabasesPanel.grouped(library)
        var out: [DatabasesPanel.Row] = []
        for (name, members) in groups {
            let shown = members.flatMap { rows(of: $0, library: true) }
            if shown.isEmpty { continue }
            out.append(.group(name, count: members.count))
            if !folded.contains(name) || !find.isEmpty { out += shown }
        }
        return out + loose.flatMap { rows(of: $0, library: true) }
    }

    /// A database's row, and what's wrong with it under it.
    private func rows(of db: DatabaseInfo, library: Bool) -> [DatabasesPanel.Row] {
        let words = [db.name, db.address, DatabaseLook.title(db.stage), db.group ?? ""].joined(separator: " ")
        if !find.isEmpty, !words.lowercased().contains(find) { return [] }
        var out: [DatabasesPanel.Row] = [.database(db, library: library)]
        if let checked = library ? libraryHealth[db.name] : health[db.name], checked.state != .ok,
            checked.state != .unknown
        {
            out.append(.problem(db, checked))
        }
        return out
    }
}
