import AgentData
import Core
import Foundation

// addons.*: what the workspace's agents get, read from their own files and from a chat's own record.

/// What `addons.*` reads with: the sessions (a chat's record, its account profile) and where Kelp's own skills are.
struct AgentAddons {
    let sessions: Sessions
}

extension AddonsList: Handled {
    func handle(_ addons: AgentAddons) throws -> Addons {
        let sessions = addons.sessions
        let worktree = try sessions.store.worktree(named: worktreeId)
        // A remote project's agents and their files are on its host: nothing to read here.
        guard sessions.remotes.of(worktree.path) == nil else { return Addons(items: [], chat: false) }
        let chat = try session.flatMap { id in try sessions.existing(id)?.snapshot ?? sessions.store.session(id) }
        let loaded = chat.flatMap(sessions.agentUsage.conversations.transcript(of:))
            .flatMap(ClaudeLoaded.read(transcript:))
        let kelp = WebApp.folders(in: sessions.root.appendingPathComponent("agent-skills")).map(\.lastPathComponent)
        // An account profile's chat reads that profile's folder.
        let own = chat?.profile.flatMap { sessions.setup.profile($0, agent: "claude") }.map {
            URL(fileURLWithPath: $0.dir)
        }
        let files = own.map { AddonFiles(claude: $0) } ?? AddonFiles()
        let items = AddonList.build(loaded: loaded, files: files, cwd: chat?.cwd ?? worktree.path, kelp: kelp.sorted())
        let off = sessions.setup.addonsOff(worktreeId: worktreeId).off
        return Addons(items: AddonSwitches.applied(off, to: items), chat: loaded != nil)
    }
}

extension AddonsSet: Handled {
    func handle(_ addons: AgentAddons) throws -> Done {
        try addons.sessions.setup.setAddon(key, on: on, worktreeId: worktreeId)
        return Done()
    }
}

extension Methods {
    static let addonMethods: [any Answered.Type] = [AddonsList.self, AddonsSet.self]
}
