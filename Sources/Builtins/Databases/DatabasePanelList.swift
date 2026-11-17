import Core

/// The Databases panel's rows in order, built from what the daemon listed and what the user folded or typed. First
/// come an agent's questions, then the project's card with its databases (a branch's copy sits under the database it
/// copies), then All My Databases by group, then what agents ran. The find field matches a database's name, address,
/// environment or group.
@MainActor
struct DatabasePanelList {
    var databases: [DatabaseInfo] = [], library: [DatabaseInfo] = [], runs: [DatabaseRun] = []
    /// What the find field holds, trimmed and lowercased.
    var find = ""
    var libraryOpen = true, activityOpen = true
    /// Shows the activity of one agent's session only; nil shows everyone's.
    var only: String?
    var folded: Set<String> = []
    var health: [String: DatabaseHealth] = [:], libraryHealth: [String: DatabaseHealth] = [:]

    var rows: [DatabasesPanel.Row] {
        var list: [DatabasesPanel.Row] = []
        let asking = runs.filter { $0.state == .asks }
        if !asking.isEmpty { list += [.heading(.asks)] + asking.map(DatabasesPanel.Row.asks) }
        // The project's card shows even when it is empty, because with All My Databases alone under it, those
        // databases would read as this project's.
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
        // The user's own reads (browsing tables in a tab) aren't news here; what agents ran, and any change, are.
        let ran = runs.filter { $0.state != .asks && ($0.session != nil || $0.changed != nil) }
            .filter { only == nil || $0.session == only }.prefix(30)
        if !ran.isEmpty, find.isEmpty {
            list.append(.heading(.activity(ran.count)))
            if activityOpen { list += ran.map(DatabasesPanel.Row.run) }
        }
        return list
    }

    /// The groups by name, each with its databases, then the databases in no group. While finding, a group shows all
    /// its databases, because a group's name finds them too.
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

    /// A database's row, with a row under it for what is wrong with the database.
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
