import Agents
import Core
import Foundation
import GitKit

// Projects and their workspaces.

extension RepoAdd: Handled {
    func handle(_ workspaces: Workspaces) throws -> Repo {
        // A remote project's own folder: it is the project (git there would answer with the host's path).
        if let repo = try workspaces.store.repos().first(where: {
            $0.path == path && workspaces.remotes.of($0.path) != nil
        }) {
            return repo
        }
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &dir), dir.boolValue else {
            throw RPCError.invalidParams("No folder at \(path).")
        }
        let root: String
        if let top = try? Git.root(of: path, remotes: workspaces.remotes) {
            root = top
        } else {
            switch `init` {
            case true?:
                try Git.run(["init", "-q"], cwd: path, remotes: workspaces.remotes)
                root = try Git.root(of: path, remotes: workspaces.remotes)
            case false?: root = Paths.real(path) ?? path   // like git's top: symlinks resolved
            case nil: throw RepoAdd.notARepository
            }
        }
        if let repo = try workspaces.store.repos().first(where: { $0.path == root }) { return repo }
        let repo = Repo(
            name: name ?? (root as NSString).lastPathComponent, path: root,
            baseBranch: Git.defaultBranch(repo: root, remotes: workspaces.remotes))
        try workspaces.store.save(repo)
        try workspaces.syncMainWorkspaces()
        workspaces.notify(ChangedEvent.repo)
        return repo
    }
}

extension RepoList: Handled { func handle(_ workspaces: Workspaces) throws -> [Repo] { try workspaces.store.repos() } }

extension ScratchEnsure: Handled {
    func handle(_ workspaces: Workspaces) throws -> Worktree {
        let scratch = ScratchChats(root: workspaces.root)
        try Paths.ensure(scratch.folder)
        scratch.dropUnusedRepo(remotes: workspaces.remotes)
        let path = Paths.real(scratch.folder.path) ?? scratch.folder.path
        var found = try workspaces.store.repos().first { $0.path == path }
        if found == nil {
            let made = Repo(
                name: "Scratch", path: path, baseBranch: Git.defaultBranch(repo: path, remotes: workspaces.remotes))
            try workspaces.store.save(made)
            try workspaces.syncMainWorkspaces()
            found = made
        }
        guard let repo = found,
            let workspace = try workspaces.store.worktrees(repo: repo.id).first(where: { !$0.archived })
        else {
            throw RPCError.internalError("no scratch workspace")
        }
        workspaces.notify(ChangedEvent.repo)
        return workspace
    }
}

extension RepoRelocate: Handled {
    func handle(_ workspaces: Workspaces) throws -> Repo {
        guard var repo = try workspaces.store.repo(id) else { throw RPCError.invalidParams("no repo") }
        let root = try Git.root(of: path, remotes: workspaces.remotes), old = repo.path
        repo.path = root
        try workspaces.store.save(repo)
        for workspace in try workspaces.store.worktrees(repo: repo.id) where workspace.path == old {
            try workspaces.store.update(Worktree.self, workspace.id) { $0.path = root }
        }
        workspaces.notify(ChangedEvent.repo)
        return repo
    }
}

/// An empty name goes back to the folder's, as `repo.add` named it (a remote project's: the folder on its host).
extension RepoRename: Handled {
    func handle(_ workspaces: Workspaces) throws -> Repo {
        guard var repo = try workspaces.store.repo(id) else { throw RPCError.invalidParams("no repo") }
        let given = name.trimmingCharacters(in: .whitespacesAndNewlines)
        repo.name =
            !given.isEmpty
            ? given
            : workspaces.remotes.of(repo.path).map { Workspaces.remoteFolderName($0.path) }
                ?? (repo.path as NSString).lastPathComponent
        try workspaces.store.save(repo)
        workspaces.notify(ChangedEvent.repo)
        return repo
    }
}

/// Its workspaces go with it, and so do their agents: none keeps working out of sight.
extension RepoRemove: Handled {
    var ends: Ending? { .project(id) }
    var notForAgents: String? { "Only the user removes a project from Kelp." }
    func handle(_ workspaces: Workspaces) throws -> Done {
        guard let repo = try workspaces.store.repo(id) else { throw RPCError.invalidParams("no repo") }
        let ids = Set(try workspaces.store.worktrees(repo: repo.id).map(\.id))
        workspaces.sessions.discard(try workspaces.store.sessions().filter { ids.contains($0.worktreeId ?? "") })
        let passwords = try workspaces.databases.accounts(ofRepo: repo.id)
        try workspaces.store.delete(repo)
        passwords.forEach(Keychain.delete)
        workspaces.notify(ChangedEvent.repo)
        return Done()
    }
}

extension WorkspaceCreate: Handled {
    var makesInProject: String? { repoId }
    func handle(_ workspaces: Workspaces) throws -> Worktree {
        guard let repo = try workspaces.store.repo(repoId) else { throw RPCError.invalidParams("no repo") }
        var workspace = try workspaces.createWorkspace(in: repo)
        if let asker = Sessions.asker {
            workspace.madeBy = asker
            try workspaces.store.save(workspace)
        }
        workspaces.sessions.events.workspaceAdded(workspace)
        return workspace
    }
}

extension WorktreeCreate: Handled {
    var makesInProject: String? { repoId }
    func handle(_ workspaces: Workspaces) throws -> Result {
        guard let repo = try workspaces.store.repo(repoId) else { throw RPCError.invalidParams("no repo") }
        // Its git would run on this Mac, not the host: a remote project's workspaces all share its folder.
        guard workspaces.remotes.of(repo.path) == nil else {
            throw RPCError.invalidParams(
                "Remote projects work in their folder: branches in worktrees aren't available there yet.")
        }
        // Opened without Git: said in words, not as git's refusal.
        do { _ = try Git.root(of: repo.path, remotes: workspaces.remotes) } catch {
            throw RPCError.invalidParams("“\(repo.name)” isn't a Git repository, so it has no branches.")
        }
        let auto = try workspaces.nextWorkspace(in: repo)
        var branch = try clientRef(branch.flatMap { $0.isEmpty ? nil : $0 }) ?? auto.branch
        // A name given for a new branch names it too, as a first prompt would (`nameBranch`), "-2" if it's taken.
        if self.branch == nil, pr == nil, let given = note?.trimmingCharacters(in: .whitespaces), !given.isEmpty,
            !Naming.slug(given).isEmpty
        {
            let wanted = workspaces.sessions.branchPrefix + Naming.slug(given)
            var suffix = 2
            branch = wanted
            while Git.branchExists(repo.path, branch, remotes: workspaces.remotes) {
                branch = "\(wanted)-\(suffix)"
                suffix += 1
            }
        }
        if let pr {
            branch = try Git.fetchPullRequest(
                repo: repo.path, number: pr, wanted: self.branch == nil ? nil : branch, remotes: workspaces.remotes)
        }
        let base = try clientRef(base.flatMap { $0.isEmpty ? nil : $0 }) ?? repo.baseBranch
        let into = Workspaces.worktreesDir(
            workspaces.root, repo, chosen: workspaces.sessions.settings[SettingKeys.worktreesFolder])
        // A pull request's code, fetched now or under what it starts from (`holdsPullRequest`): it gets none of the project's
        // own files (.env), and nothing of .kelp.yaml runs on it until the user says so (below).
        let checksOut = existing == true || pr != nil
        let fromPR =
            pr != nil || Git.holdsPullRequest(repo.path, at: checksOut ? branch : base, remotes: workspaces.remotes)
        let path = try Git.addWorktree(
            repo: repo.path, branch: branch, base: base, into: into, copyFiles: repo.copyFiles,
            existing: checksOut, copying: !fromPR, remotes: workspaces.remotes)
        // "origin/x" checked out as the local "x" that follows it
        if existing == true, !Git.branchExists(repo.path, branch, remotes: workspaces.remotes) {
            branch = branch.split(separator: "/", maxSplits: 1).last.map(String.init) ?? branch
        }
        var workspace = Worktree(
            repoId: repo.id, branch: branch, path: path, note: note ?? (self.branch == nil ? auto.name : ""), base: base
        )
        workspace.madeBy = Sessions.asker
        try workspaces.store.save(workspace)
        var result = Result(worktree: workspace)
        // Everything .kelp.yaml does waits for the user's trust in this version of the file, not only `setup`: `tabs`
        // starts agents and `shared` links folders, and a freshly cloned repository wrote that file, not the user.
        // Checked and used from one read. A pull request brings code the file's trust doesn't cover (an install script of
        // its author's): nothing runs on it until the user says so, nor on a branch made on top of one (`fromPR`).
        let read = workspaces.configAndTrust(repo.path), cfg = read.config, trusted = read.trusted && !fromPR
        if trusted {
            Git.linkShared(cfg.shared, repo: repo.path, worktree: path)
            for why in Git.cloneShared(cfg.clone, repo: repo.path, worktree: path) {
                Log.session.error(
                    ".kelp.yaml clone left out \(why, privacy: .public): the worktree is on another volume, or the path is busy"
                )
            }
            if tabs != false {
                for tab in cfg.tabs {
                    do {
                        _ = try workspaces.sessions.spawn(
                            cwd: path, manifest: workspaces.sessions.setup.manifest(tab, command: nil),
                            worktreeId: workspace.id)
                    } catch { Log.session.error(".kelp.yaml tab \(tab, privacy: .public) didn't start: \(error)") }
                }
            }
        }
        let asks = cfg.setup != nil || !cfg.tabs.isEmpty || !cfg.shared.isEmpty || !cfg.clone.isEmpty
        if asks, setup != false, !trusted {
            result.setupNeedsTrust = true   // the app asks, then scripts.trust + scripts.run "setup"
        } else if let cmd = cfg.setup, setup != false {
            var launch = Sessions.Launch()
            launch.title = "setup"
            let session = try workspaces.sessions.spawn(
                cwd: path, manifest: .custom(cfg.shell(cmd)), worktreeId: workspace.id, launch)
            result.setupSession = session.id
        }
        workspaces.notify(ChangedEvent.worktree)
        workspaces.sessions.events.workspaceAdded(result.worktree)
        return result
    }
}

/// Only reads: workspaces follow their folders' branches as they change (`watchHeads`), not when someone lists them.
extension WorktreeList: Handled {
    func handle(_ workspaces: Workspaces) throws -> [Worktree] {
        try workspaces.store.worktrees(repo: repoId).filter { archived == true || !$0.archived }
    }
}

extension WorktreeArchive: Handled {
    var ends: Ending? { .workspace(id) }
    func handle(_ workspaces: Workspaces) throws -> Done {
        guard let workspace = try workspaces.store.worktree(id), let repo = try workspaces.store.repo(workspace.repoId)
        else {
            throw RPCError.invalidParams("no worktree")
        }
        try workspaces.archive(workspace, repo)
        return Done()
    }
}

extension WorktreeRemove: Handled {
    var ends: Ending? { .workspace(id) }
    var notForAgents: String? {
        force == true || dropCommits == true ? "Only the user removes a workspace with its changes or commits." : nil
    }
    func handle(_ workspaces: Workspaces) throws -> Done {
        guard let workspace = try workspaces.store.worktree(id), let repo = try workspaces.store.repo(workspace.repoId)
        else {
            throw RPCError.invalidParams("no worktree")
        }
        if workspaces.isMain(workspace, repo) {
            try workspaces.removeWorkspace(workspace, repo)
            return Done()
        }
        if Workspaces.borrowed(workspace.path, seed: Paths.seed) {
            try workspaces.sessions.pauseSessions(of: workspace.id)
            workspaces.sessions.discard(try workspaces.store.sessions().filter { $0.worktreeId == workspace.id })
            try workspaces.store.delete(workspace)
            workspaces.notify(ChangedEvent.worktree)
            return Done()
        }
        let branch = workspaces.branchNow(of: workspace, in: repo)
        let force = force == true, drop = dropCommits == true
        // A remote project's folder is on its host: looked for there.
        let host = workspaces.remotes.of(repo.path)   // the project's: its worktrees are on its host too
        let exists =
            try host.map {
                String(
                    decoding: try $0.run("[ -e \(ShellQuote.word(workspace.path)) ] && echo yes || true"), as: UTF8.self
                )
                .hasPrefix("yes")
            }
            ?? FileManager.default.fileExists(atPath: workspace.path)
        if exists {
            // Refuse before anything stops; then stop its agents and only then remove, checking again: an agent still
            // writing can't have its work deleted under it.
            try Git.checkRemovable(
                repo: repo.path, path: workspace.path, branch: branch, force: force, dropCommits: drop,
                remotes: workspaces.remotes
            )
            try workspaces.sessions.pauseSessions(of: workspace.id)
            try Git.removeWorktree(
                repo: repo.path, path: workspace.path, branch: branch, force: force, dropCommits: drop,
                remotes: workspaces.remotes
            )
        } else {
            try workspaces.sessions.pauseSessions(of: workspace.id)
            // Gone already (a removal that stopped after the Trash): git's record and the branch mustn't stay behind.
            try Git.forgetWorktree(
                repo: repo.path, path: workspace.path, branch: branch, dropCommits: drop, remotes: workspaces.remotes)
        }
        // Its sessions' turn refs live in the project's repository: dropped there, once the folder is gone. Not before:
        // a removal that fails keeps the workspace, and its turns keep their snapshots.
        for session in try workspaces.store.sessions() where session.worktreeId == workspace.id {
            workspaces.sessions.turns.dropRefs(of: session.id, in: repo.path)
        }
        workspaces.sessions.discard(try workspaces.store.sessions().filter { $0.worktreeId == workspace.id })
        try workspaces.store.delete(workspace)
        workspaces.notify(ChangedEvent.worktree)
        return Done()
    }
}

extension WorktreeUnarchive: Handled {
    func handle(_ workspaces: Workspaces) throws -> Done {
        guard try workspaces.store.update(Worktree.self, id, { $0.archived = false }) != nil else {
            throw RPCError.invalidParams("no worktree")
        }
        workspaces.notify(ChangedEvent.worktree)
        return Done()
    }
}

extension WorktreeUnmerged: Handled {
    func handle(_ workspaces: Workspaces) throws -> Int {
        let workspace = try workspaces.store.worktree(named: id)
        guard let repo = try workspaces.store.repo(workspace.repoId) else { return 0 }
        let branch = workspaces.branchNow(of: workspace, in: repo)
        guard Git.branchExists(repo.path, branch, remotes: workspaces.remotes) else { return 0 }
        return try Git.onlyOnBranch(repo: repo.path, branch, remotes: workspaces.remotes)
    }
}

extension WorktreeDirty: Handled {
    func handle(_ workspaces: Workspaces) throws -> Bool {
        try Git.isDirty(workspaces.folder(id), remotes: workspaces.remotes)
    }
}

extension Workspaces {
    /// Archiving keeps the folder, ignored files (.env, node_modules, builds) and all: its agents pause, and unarchiving
    /// finds everything where it was. A project keeps at least one workspace.
    func archive(_ workspace: Worktree, _ repo: Repo) throws {
        if isMain(workspace, repo),
            try store.worktrees(repo: repo.id).filter({ isMain($0, repo) && !$0.archived }).count < 2
        {
            throw RPCError.invalidParams("A project keeps at least one workspace.")
        }
        try sessions.pauseSessions(of: workspace.id)
        try store.update(Worktree.self, workspace.id) { $0.archived = true }
        notify(ChangedEvent.worktree)
    }

    func removeWorkspace(_ workspace: Worktree, _ repo: Repo) throws {
        guard try store.worktrees(repo: repo.id).filter({ isMain($0, repo) }).count > 1 else {
            throw RPCError.invalidParams("A project keeps at least one workspace; remove the project instead.")
        }
        sessions.discard(try store.sessions().filter { $0.worktreeId == workspace.id })
        try store.delete(workspace)
        notify(ChangedEvent.worktree)
    }
}

extension Methods {
    static let workspaceMethods: [any Handled.Type] = [
        RepoAdd.self, RepoList.self, ScratchEnsure.self, RepoRelocate.self, RepoRename.self, RepoRemove.self,
        WorkspaceCreate.self, WorktreeCreate.self, WorktreeList.self, WorktreeArchive.self, WorktreeRemove.self,
        WorktreeUnarchive.self,
        WorktreeUnmerged.self, WorktreeDirty.self
    ]
}
