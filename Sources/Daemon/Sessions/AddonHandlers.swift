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
            builtIn: ClaudeBuiltIns.names, kelpHome: sessions.root)
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

extension AddonsEntry: Handled {
    func handle(_ addons: AgentAddons) throws -> ServerEntry {
        let setup = addons.sessions.setup, worktree = try setup.store.worktree(named: worktreeId)
        let name = String(key.dropFirst("server:".count))
        let shared = URL(fileURLWithPath: worktree.path).appendingPathComponent(".mcp.json")
        let files = AddonFiles()
        let found =
            ServerFiles.read(setup.serversFile)[name] ?? ServerFiles.read(shared)[name]
            ?? files.entry(name, of: "claude", cwd: worktree.path) ?? files.entry(name, of: "codex", cwd: worktree.path)
        guard key.hasPrefix("server:"), let found else {
            throw RPCError.invalidParams("no file here names a server \(name)")
        }
        return found
    }
}

/// `key` as a skill of the person's own; anything else isn't theirs to move.
private func ownSkill(_ key: String) throws -> String {
    guard key.hasPrefix("skill:"), !key.dropFirst(6).contains(":") else {
        throw RPCError.invalidParams("only a skill in your own folders or the project's")
    }
    return String(key.dropFirst(6))
}

extension AddonsTrash: Handled {
    func handle(_ addons: AgentAddons) throws -> Done {
        let setup = addons.sessions.setup, worktree = try setup.store.worktree(named: worktreeId)
        try AddonFiles().trashSkill(try ownSkill(key), cwd: worktree.path)
        try setup.setAddon(key, on: true, worktreeId: worktreeId)   // its switch goes with it
        return Done()
    }
}

extension AddonsLink: Handled {
    func handle(_ addons: AgentAddons) throws -> Done {
        let worktree = try addons.sessions.setup.store.worktree(named: worktreeId)
        try AddonFiles().linkSkill(try ownSkill(key), cwd: worktree.path)
        return Done()
    }
}

extension AddonsInstall: Handled {
    func handle(_ addons: AgentAddons) throws -> [String] {
        let worktree = try addons.sessions.setup.store.worktree(named: worktreeId), files = AddonFiles()
        guard let source, !source.isEmpty else {
            return [try files.newSkill(name ?? "", cwd: worktree.path, project: project)]
        }
        let local = URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: local.path) {
            return try files.installSkills(from: local, cwd: worktree.path, project: project)
        }
        // A repository: one shallow clone into a folder of its own name, read, then gone.
        guard let url = URL(string: source), ["https", "ssh", "git"].contains(url.scheme ?? "") else {
            throw RPCError.invalidParams("a folder here or a git address: \(source)")
        }
        let name = url.deletingPathExtension().lastPathComponent
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-skill-\(UUID().uuidString)")
        defer { FileManager.default.removeIfAny(temp) }
        let clone = temp.appendingPathComponent(name)
        try Paths.ensure(temp)
        let result = try Subprocess.run(
            [try LoginPath.resolve("git"), "clone", "--depth", "1", "--quiet", source, clone.path], cwd: temp.path,
            env: ["GIT_TERMINAL_PROMPT": "0", "PATH": Sessions.childPath], timeLimit: 90)
        guard result.status == 0, !result.timedOut else {
            let said = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw RPCError.internalError("git couldn't fetch it: \(said.isEmpty ? "no answer" : said)")
        }
        return try files.installSkills(from: clone, cwd: worktree.path, project: project)
    }
}

extension Methods {
    static let addonMethods: [any Answered.Type] = [
        AddonsList.self, AddonsSet.self, AddonsAdd.self, AddonsRemove.self, AddonsEntry.self, AddonsTrash.self,
        AddonsLink.self, AddonsInstall.self
    ]
}
