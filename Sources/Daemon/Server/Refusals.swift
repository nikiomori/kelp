import Core

/// The daemon's answers when a call names a record it doesn't have: what wasn't found, why that usually is, and where
/// the ones that are can be listed. The id is the caller's own, so it's safe to say back.
extension RPCError {
    static func noProject(_ id: String) -> RPCError {
        .invalidParams("No project \(id): it was removed, or the id is wrong. `kelp repo list` lists the projects.")
    }

    static func noWorkspace(_ id: String) -> RPCError {
        .invalidParams(
            "No workspace \(id): it was removed, or the id is wrong. `kelp worktree list --all` lists the workspaces.")
    }

    static func noSession(_ id: String) -> RPCError {
        .invalidParams("No session \(id): it was deleted, or the id is wrong. `kelp session list` lists the sessions.")
    }

    /// The session is known but no longer runs, so nothing can be typed into it or read from it live.
    static func notRunning(_ id: String) -> RPCError {
        .invalidParams("Session \(id) has ended: restart it (`kelp session restart \(id)`) or start a new one.")
    }
}
