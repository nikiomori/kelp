import Core
import Foundation

// session.move and session.rename: which screen a session is on, and its title.

extension SessionMove: Handled {
    func handle(_ sessions: Sessions) throws -> Done {
        guard let to = try sessions.store.worktree(worktreeId), !to.archived else {
            throw RPCError.invalidParams("no worktree")
        }
        try sessions.wakeLocks.withLock(id) {
            guard
                let session = try sessions.existing(id)?.snapshot
                    ?? sessions.store.sessions().first(where: { $0.id == id })
            else {
                throw RPCError.invalidParams("no session")
            }
            // Its process keeps its folder: a workspace elsewhere is other files, which only a new agent can have.
            guard let from = try session.worktreeId.flatMap(sessions.store.worktree), from.path == to.path else {
                throw RPCError.invalidParams("Only a screen of the same folder can take it.")
            }
            try sessions.edit(id, held: true) { $0.worktreeId = worktreeId }
            // Before the reply, as a record written in the store is: the app finds it on its new screen.
            if let ls = sessions.existing(id) { sessions.notify(ls.snapshot) }
        }
        return Done()
    }
}

extension SessionRename: Handled {
    var actsOn: String? { id }   // its title on the user's row: an agent names only its own and those it started
    func handle(_ sessions: Sessions) throws -> Done {
        try sessions.edit(id) { [title] in
            $0.title = title
            $0.titleManual = !title.isEmpty
        }
        return Done()
    }
}

extension Methods {
    static let sessionEditMethods: [any Answered.Type] = [SessionMove.self, SessionRename.self]
}
