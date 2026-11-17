import Core
import Foundation

// session.move and session.rename: which screen a session is on, and its title.

extension SessionMove: Handled {
    func handle(_ sessions: Sessions) throws -> Done {
        guard let to = try sessions.store.worktree(worktreeId), !to.archived else {
            throw RPCError.noWorkspace(worktreeId)
        }
        try sessions.wakeLocks.withLock(id) {
            guard
                let session = try sessions.existing(id)?.snapshot
                    ?? sessions.store.sessions().first(where: { $0.id == id })
            else {
                throw RPCError.noSession(id)
            }
            // The session's process keeps its folder, and a workspace elsewhere is other files, which only a new agent
            // can have.
            guard let from = try session.worktreeId.flatMap(sessions.store.worktree), from.path == to.path else {
                throw RPCError.invalidParams("Only a screen of the same folder can take it.")
            }
            try sessions.edit(id, held: true) { $0.worktreeId = worktreeId }
            // Sent before the reply, as a record written in the store is, so the app finds the session on its new
            // screen.
            if let ls = sessions.existing(id) { sessions.notify(ls.snapshot) }
        }
        return Done()
    }
}

extension SessionRename: Handled {
    static let agents = AgentAccess.acts
    // the title shows on the user's row, so an agent renames only its own sessions and those it started
    var fence: Fence { Fence(actsOn: id) }
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
