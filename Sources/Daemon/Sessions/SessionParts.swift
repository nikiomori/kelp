// Parts of `Sessions` a service is handed instead of all of it, so its handlers reach only those.
import Agents
import Core
import Foundation

/// What a workspace does with its sessions: starts the ones its .kelp.yaml and its runs name, pauses them before it goes
/// away and lets go of their records then, and reads what runs in it. It never wakes, types into, restarts, moves or
/// hands off a session: `Workspaces` keeps this, not all of `Sessions`.
protocol WorkspaceSessions: Sendable {
    var setup: SessionSetup { get }
    var live: SessionTable { get }
    var turns: Turns { get }
    var events: ExtensionEvents { get }
    var settings: SettingsStore { get }
    var branchPrefix: String { get }
    func spawn(cwd: String, manifest: AgentManifest, worktreeId: String?, _ launch: Sessions.Launch) throws -> Session
    func pauseSessions(of wid: String) throws
    func discard(_ all: [Session], keepTmux: Bool)
}

extension WorkspaceSessions {
    func spawn(cwd: String, manifest: AgentManifest, worktreeId: String?) throws -> Session {
        try spawn(cwd: cwd, manifest: manifest, worktreeId: worktreeId, Sessions.Launch())
    }
    func discard(_ all: [Session]) { discard(all, keepTmux: false) }
    func existing(_ id: String) -> LiveSession? { live[id] }
}

/// What asking the user on an agent's row takes (a page it wants opened, a machine it would make): who calls, the
/// agent's session, and the question's wait.
struct AgentAsks: Sendable {
    let store: Store, live: SessionTable, permissions: PermissionWaits, clients: Clients
    func existing(_ id: String) -> LiveSession? { live[id] }
}
