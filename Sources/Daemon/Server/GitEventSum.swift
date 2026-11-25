import Core
import Foundation

extension GitEvent {
    /// The git state of a folder that holds several repositories (`RepoKey`): each one read by `read` (its key and
    /// name) as a folder of its own is, summed up here with each one's paths under its name, so what the sidebar, ⌃Tab
    /// and the window bar say of the folder (its lines, what only a branch group holds, whether it has changes) counts
    /// them all. `repos` names them and `repoBranches` holds their branches; `branches` stays nil, as there is no one
    /// branch. A repository that can't be read is left out; when none can, the event says why. Limit: the
    /// repositories are read one after another.
    static func sum(_ key: String, _ names: [String], read: (String, String) async -> GitEvent) async -> GitEvent {
        var event = GitEvent(worktree: key, changes: [], stats: LineStats())
        event.repos = names
        var errors: [String] = []
        for name in names {
            let one = await read(RepoKey.of(key, name), name)
            if let error = one.error {
                errors.append("\(name): \(error)")
                continue
            }
            event.changes? += (one.changes ?? []).map {
                FileChange(path: name + "/" + $0.path, index: $0.index, worktree: $0.worktree)
            }
            event.stats = event.stats.map { $0.adding(one.stats) }
            if let files = one.branchFiles {
                event.branchFiles = (event.branchFiles ?? []) + files.map { name + "/" + $0 }
            }
            if let only = one.only { event.only = (event.only ?? 0) + only }
            if let dirty = one.dirty { event.dirty = (event.dirty ?? false) || dirty }
            if let branches = one.branches {
                event.repoBranches = (event.repoBranches ?? [:]).merging([name: branches]) { $1 }
            }
        }
        if errors.count == names.count { event = GitEvent(worktree: key, error: errors.joined(separator: "\n")) }
        return event
    }
}

extension LineStats {
    /// These counts and `other`'s together, kind by kind (nil adds nothing).
    func adding(_ other: LineStats?) -> LineStats {
        guard let other else { return self }
        return LineStats(
            added: added.merging(other.added, uniquingKeysWith: +),
            removed: removed.merging(other.removed, uniquingKeysWith: +))
    }
}
