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
        let kept = ServerFiles.read(sessions.setup.serversFile).keys.sorted()
        // Which skills are Claude Code's own: learnt from its /context, read once here if nothing read one yet.
        if loaded != nil, ClaudeBuiltIns.names == nil, let chat { _ = sessions.setup.claudeSetup(chat) }
        let (items, gone) = AddonList.list(
            loaded: loaded, files: files, cwd: chat?.cwd ?? worktree.path, kelp: kelp.sorted(), kept: kept,
            builtIn: ClaudeBuiltIns.names)
        let off = sessions.setup.addonsOff(worktreeId: worktreeId).off
        return Addons(items: AddonSwitches.applied(off, to: items), chat: loaded != nil, gone: gone)
    }
}

extension AddonsSet: Handled {
    func handle(_ addons: AgentAddons) throws -> Done {
        try addons.sessions.setup.setAddon(key, on: on, worktreeId: worktreeId)
        return Done()
    }
}

extension AddonsAdd: Handled {
    func handle(_ addons: AgentAddons) throws -> Done {
        let setup = addons.sessions.setup, worktree = try setup.store.worktree(named: worktreeId)
        let found = entry ?? from.flatMap { AddonFiles().entry(name, of: $0, cwd: worktree.path) }
        guard let found, found.command != nil || found.url != nil else {
            throw RPCError.invalidParams("a server needs a command or an address")
        }
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            throw RPCError.invalidParams("a server's name is letters, digits, - and _")
        }
        let file = project ? URL(fileURLWithPath: worktree.path).appendingPathComponent(".mcp.json") : setup.serversFile
        try ServerFiles.write(name, found, to: file)
        // Kelp's own holds what servers sign in with: the person's only.
        if !project { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        return Done()
    }
}

extension AddonsRemove: Handled {
    func handle(_ addons: AgentAddons) throws -> Done {
        let setup = addons.sessions.setup, worktree = try setup.store.worktree(named: worktreeId)
        guard key.hasPrefix("server:") else { throw RPCError.invalidParams("only a server is removed") }
        let name = String(key.dropFirst(7)), mine = setup.serversFile
        let shared = URL(fileURLWithPath: worktree.path).appendingPathComponent(".mcp.json")
        guard let file = [mine, shared].first(where: { ServerFiles.read($0)[name] != nil }) else {
            throw RPCError.invalidParams("Kelp didn't add \(name): it's in the agent's own settings")
        }
        try ServerFiles.write(name, nil, to: file)
        try setup.setAddon(key, on: true, worktreeId: worktreeId)   // its switch goes with it
        return Done()
    }
}

extension Methods {
    static let addonMethods: [any Answered.Type] = [AddonsList.self, AddonsSet.self, AddonsAdd.self, AddonsRemove.self]
}
