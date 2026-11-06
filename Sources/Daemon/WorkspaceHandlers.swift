import Foundation
import Core
import GitKit
import Agents

// Projects and their workspaces.

extension RepoAdd: Handled {
    func handle(_ workspaces: Workspaces) throws -> Repo {
        // A remote project's own folder: it is the project (git there would answer with the host's path).
        if let r = try workspaces.store.repos().first(where: { $0.path == path && workspaces.remotes.of($0.path) != nil }) { return r }
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &dir), dir.boolValue else { throw RPCError.invalidParams("No folder at \(path).") }
        let root: String
        if let top = try? Git.root(of: path, remotes: workspaces.remotes) { root = top } else {
            switch `init` {
            case true?: try Git.run(["init", "-q"], cwd: path, remotes: workspaces.remotes); root = try Git.root(of: path, remotes: workspaces.remotes)
            case false?: root = Paths.real(path) ?? path   // like git's top: symlinks resolved
            case nil: throw RepoAdd.notARepository
            }
        }
        if let r = try workspaces.store.repos().first(where: { $0.path == root }) { return r }
        let r = Repo(name: name ?? (root as NSString).lastPathComponent, path: root, baseBranch: Git.defaultBranch(repo: root, remotes: workspaces.remotes))
        try workspaces.store.save(r)
        try workspaces.syncMainWorkspaces()
        workspaces.notify(ChangedEvent.repo)
        return r
    }
}

extension RepoList: Handled { func handle(_ workspaces: Workspaces) throws -> [Repo] { try workspaces.store.repos() } }

extension ScratchEnsure: Handled {
    func handle(_ workspaces: Workspaces) throws -> Worktree {
        let scratch = ScratchChats(root: workspaces.root)
        try Paths.ensure(scratch.folder)
        scratch.dropUnusedRepo(remotes: workspaces.remotes)
        let path = Paths.real(scratch.folder.path) ?? scratch.folder.path
        var r = try workspaces.store.repos().first { $0.path == path }
        if r == nil {
            let n = Repo(name: "Scratch", path: path, baseBranch: Git.defaultBranch(repo: path, remotes: workspaces.remotes))
            try workspaces.store.save(n)
            try workspaces.syncMainWorkspaces()
            r = n
        }
        guard let repo = r, let w = try workspaces.store.worktrees(repo: repo.id).first(where: { !$0.archived }) else {
            throw RPCError.internalError("no scratch workspace")
        }
        workspaces.notify(ChangedEvent.repo)
        return w
    }
}

extension RepoRelocate: Handled {
    func handle(_ workspaces: Workspaces) throws -> Repo {
        guard var r = try workspaces.store.repo(id) else { throw RPCError.invalidParams("no repo") }
        let root = try Git.root(of: path, remotes: workspaces.remotes), old = r.path
        r.path = root; try workspaces.store.save(r)
        for w in try workspaces.store.worktrees(repo: r.id) where w.path == old { try workspaces.store.update(Worktree.self, w.id) { $0.path = root } }
        workspaces.notify(ChangedEvent.repo)
        return r
    }
}

/// An empty name goes back to the folder's, as `repo.add` named it (a remote project's: the folder on its host).
extension RepoRename: Handled {
    func handle(_ workspaces: Workspaces) throws -> Repo {
        guard var r = try workspaces.store.repo(id) else { throw RPCError.invalidParams("no repo") }
        let given = name.trimmingCharacters(in: .whitespacesAndNewlines)
        r.name = !given.isEmpty ? given
            : workspaces.remotes.of(r.path).map { Workspaces.remoteFolderName($0.path) } ?? (r.path as NSString).lastPathComponent
        try workspaces.store.save(r)
        workspaces.notify(ChangedEvent.repo)
        return r
    }
}

/// Its workspaces go with it, and so do their agents: none keeps working out of sight.
extension RepoRemove: Handled {
    var ends: Ending? { .project(id) }
    var notForAgents: String? { "Only the user removes a project from Kelp." }
    func handle(_ workspaces: Workspaces) throws -> Done {
        guard let r = try workspaces.store.repo(id) else { throw RPCError.invalidParams("no repo") }
        let ids = Set(try workspaces.store.worktrees(repo: r.id).map(\.id))
        workspaces.sessions.discard(try workspaces.store.sessions().filter { ids.contains($0.worktreeId ?? "") })
        try workspaces.store.delete(r); workspaces.notify(ChangedEvent.repo)
        return Done()
    }
}

extension WorkspaceCreate: Handled {
    func handle(_ workspaces: Workspaces) throws -> Worktree {
        guard let r = try workspaces.store.repo(repoId) else { throw RPCError.invalidParams("no repo") }
        let w = try workspaces.createWorkspace(in: r)
        if let a = Sessions.asker { workspaces.sessions.made.withLock { $0[w.id] = a } }
        workspaces.sessions.workspaceAdded(w)
        return w
    }
}

extension WorktreeCreate: Handled {
    func handle(_ workspaces: Workspaces) throws -> Result {
        guard let r = try workspaces.store.repo(repoId) else { throw RPCError.invalidParams("no repo") }
        // Its git would run on this Mac, not the host: a remote project's workspaces all share its folder.
        guard workspaces.remotes.of(r.path) == nil else {
            throw RPCError.invalidParams("Remote projects work in their folder: branches in worktrees aren't available there yet.")
        }
        // Opened without Git: said in words, not as git's refusal.
        do { _ = try Git.root(of: r.path, remotes: workspaces.remotes) } catch {
            throw RPCError.invalidParams("“\(r.name)” isn't a Git repository, so it has no branches.")
        }
        let auto = try workspaces.nextWorkspace(in: r)
        var branch = try clientRef(branch.flatMap { $0.isEmpty ? nil : $0 }) ?? auto.branch
        // A name given for a new branch names it too, as a first prompt would (`nameBranch`), "-2" if it's taken.
        if self.branch == nil, pr == nil, let n = note?.trimmingCharacters(in: .whitespaces), !n.isEmpty, !Naming.slug(n).isEmpty {
            let wanted = workspaces.sessions.branchPrefix + Naming.slug(n)
            var k = 2
            branch = wanted
            while Git.branchExists(r.path, branch, remotes: workspaces.remotes) { branch = "\(wanted)-\(k)"; k += 1 }
        }
        if let pr { branch = try Git.fetchPullRequest(repo: r.path, number: pr, wanted: self.branch == nil ? nil : branch, remotes: workspaces.remotes) }
        let base = try clientRef(base.flatMap { $0.isEmpty ? nil : $0 }) ?? r.baseBranch
        let into = Workspaces.worktreesDir(workspaces.root, r, chosen: workspaces.sessions.settings["worktrees.folder"]?.string)
        // A pull request's code, fetched now or under what it starts from (`holdsPullRequest`): it gets none of the project's
        // own files (.env), and nothing of .kelp.yaml runs on it until the user says so (below).
        let checksOut = existing == true || pr != nil
        let fromPR = pr != nil || Git.holdsPullRequest(r.path, at: checksOut ? branch : base, remotes: workspaces.remotes)
        let path = try Git.addWorktree(repo: r.path, branch: branch, base: base, into: into, copyFiles: r.copyFiles,
                                       existing: checksOut, copying: !fromPR, remotes: workspaces.remotes)
        // "origin/x" checked out as the local "x" that follows it
        if existing == true, !Git.branchExists(r.path, branch, remotes: workspaces.remotes) {
            branch = branch.split(separator: "/", maxSplits: 1).last.map(String.init) ?? branch
        }
        let w = Worktree(repoId: r.id, branch: branch, path: path, note: note ?? (self.branch == nil ? auto.name : ""), base: base)
        try workspaces.store.save(w)
        if let a = Sessions.asker { workspaces.sessions.made.withLock { $0[w.id] = a } }
        var result = Result(worktree: w)
        // Everything .kelp.yaml does waits for the user's trust in this version of the file, not only `setup`: `tabs`
        // starts agents and `shared` links folders, and a freshly cloned repository wrote that file, not the user.
        // Checked and used from one read. A pull request brings code the file's trust doesn't cover (an install script of
        // its author's): nothing runs on it until the user says so, nor on a branch made on top of one (`fromPR`).
        let read = workspaces.configAndTrust(r.path), cfg = read.config, trusted = read.trusted && !fromPR
        if trusted {
            Git.linkShared(cfg.shared, repo: r.path, worktree: path)
            for why in Git.cloneShared(cfg.clone, repo: r.path, worktree: path) {
                Log.session.error(".kelp.yaml clone left out \(why, privacy: .public): the worktree is on another volume, or the path is busy")
            }
            if tabs != false {
                for t in cfg.tabs {
                    do { _ = try workspaces.sessions.spawn(cwd: path, manifest: workspaces.sessions.manifest(t, command: nil), worktreeId: w.id) }
                    catch { Log.session.error(".kelp.yaml tab \(t, privacy: .public) didn't start: \(error)") }
                }
            }
        }
        let asks = cfg.setup != nil || !cfg.tabs.isEmpty || !cfg.shared.isEmpty || !cfg.clone.isEmpty
        if asks, setup != false, !trusted {
            result.setupNeedsTrust = true   // the app asks, then scripts.trust + scripts.run "setup"
        } else if let cmd = cfg.setup, setup != false {
            var o = Sessions.Launch(); o.title = "setup"
            let s = try workspaces.sessions.spawn(cwd: path, manifest: .custom(cmd), worktreeId: w.id, o)
            result.setupSession = s.id
        }
        workspaces.notify(ChangedEvent.worktree)
        workspaces.sessions.workspaceAdded(result.worktree)
        return result
    }
}

/// Only reads: workspaces follow their folders' branches as they change (`watchHeads`), not when someone lists them.
extension WorktreeList: Handled {
    func handle(_ workspaces: Workspaces) throws -> [Worktree] { try workspaces.store.worktrees(repo: repoId).filter { archived == true || !$0.archived } }
}

extension WorktreeArchive: Handled {
    var ends: Ending? { .workspace(id) }
    var inWorkspace: String? { id }   // one with no sessions ends none: still not another's to put away
    func handle(_ workspaces: Workspaces) throws -> Done {
        guard let w = try workspaces.store.worktree(id), let r = try workspaces.store.repo(w.repoId) else { throw RPCError.invalidParams("no worktree") }
        try workspaces.archive(w, r); return Done()
    }
}

extension WorktreeRemove: Handled {
    var ends: Ending? { .workspace(id) }
    var inWorkspace: String? { id }   // one with no sessions ends none: still not another's to remove
    var notForAgents: String? { force == true || dropCommits == true ? "Only the user removes a workspace with its changes or commits." : nil }
    func handle(_ workspaces: Workspaces) throws -> Done {
        guard let w = try workspaces.store.worktree(id), let r = try workspaces.store.repo(w.repoId) else { throw RPCError.invalidParams("no worktree") }
        if workspaces.isMain(w, r) { try workspaces.removeWorkspace(w, r); return Done() }
        if Workspaces.borrowed(w.path, seed: Paths.seed) {
            try workspaces.sessions.pauseSessions(of: w.id)
            workspaces.sessions.discard(try workspaces.store.sessions().filter { $0.worktreeId == w.id })
            try workspaces.store.delete(w)
            workspaces.notify(ChangedEvent.worktree)
            return Done()
        }
        let branch = workspaces.branchNow(of: w, in: r)
        let force = force == true, drop = dropCommits == true
        // A remote project's folder is on its host: looked for there.
        let host = workspaces.remotes.of(r.path)   // the project's: its worktrees are on its host too
        let exists = try host.map { String(decoding: try $0.run("[ -e \(IDE.shellWord(w.path)) ] && echo yes || true"), as: UTF8.self).hasPrefix("yes") }
            ?? FileManager.default.fileExists(atPath: w.path)
        if exists {
            // Refuse before anything stops; then stop its agents and only then remove, checking again: an agent still
            // writing can't have its work deleted under it.
            try Git.checkRemovable(repo: r.path, path: w.path, branch: branch, force: force, dropCommits: drop, remotes: workspaces.remotes)
            try workspaces.sessions.pauseSessions(of: w.id)
            try Git.removeWorktree(repo: r.path, path: w.path, branch: branch, force: force, dropCommits: drop, remotes: workspaces.remotes)
        } else {
            try workspaces.sessions.pauseSessions(of: w.id)
            // Gone already (a removal that stopped after the Trash): git's record and the branch mustn't stay behind.
            try Git.forgetWorktree(repo: r.path, path: w.path, branch: branch, dropCommits: drop, remotes: workspaces.remotes)
        }
        // Its sessions' turn refs live in the project's repository: dropped there, once the folder is gone. Not before:
        // a removal that fails keeps the workspace, and its turns keep their snapshots.
        for s in try workspaces.store.sessions() where s.worktreeId == w.id { workspaces.sessions.dropTurnRefs(of: s.id, in: r.path) }
        workspaces.sessions.discard(try workspaces.store.sessions().filter { $0.worktreeId == w.id })
        try workspaces.store.delete(w)
        workspaces.notify(ChangedEvent.worktree)
        return Done()
    }
}

extension WorktreeUnarchive: Handled {
    func handle(_ workspaces: Workspaces) throws -> Done {
        guard try workspaces.store.update(Worktree.self, id, { $0.archived = false }) != nil else { throw RPCError.invalidParams("no worktree") }
        workspaces.notify(ChangedEvent.worktree)
        return Done()
    }
}

extension WorktreeUnmerged: Handled {
    func handle(_ workspaces: Workspaces) throws -> Int {
        let w = try workspaces.store.worktree(named: id)
        guard let r = try workspaces.store.repo(w.repoId) else { return 0 }
        let branch = workspaces.branchNow(of: w, in: r)
        guard Git.branchExists(r.path, branch, remotes: workspaces.remotes) else { return 0 }
        return try Git.onlyOnBranch(repo: r.path, branch, remotes: workspaces.remotes)
    }
}

extension WorktreeDirty: Handled {
    func handle(_ workspaces: Workspaces) throws -> Bool { try Git.isDirty(workspaces.folder(id), remotes: workspaces.remotes) }
}

extension Workspaces {
    /// Archiving keeps the folder, ignored files (.env, node_modules, builds) and all: its agents pause, and unarchiving
    /// finds everything where it was. A project keeps at least one workspace.
    func archive(_ w: Worktree, _ r: Repo) throws {
        if isMain(w, r), try store.worktrees(repo: r.id).filter({ isMain($0, r) && !$0.archived }).count < 2 {
            throw RPCError.invalidParams("A project keeps at least one workspace.")
        }
        try sessions.pauseSessions(of: w.id)
        try store.update(Worktree.self, w.id) { $0.archived = true }
        notify(ChangedEvent.worktree)
    }

    func removeWorkspace(_ w: Worktree, _ r: Repo) throws {
        guard try store.worktrees(repo: r.id).filter({ isMain($0, r) }).count > 1 else {
            throw RPCError.invalidParams("A project keeps at least one workspace; remove the project instead.")
        }
        sessions.discard(try store.sessions().filter { $0.worktreeId == w.id })
        try store.delete(w)
        notify(ChangedEvent.worktree)
    }
}

extension Methods {
    static let workspaceMethods: [any Handled.Type] = [RepoAdd.self, RepoList.self, ScratchEnsure.self, RepoRelocate.self, RepoRename.self, RepoRemove.self,
        WorkspaceCreate.self, WorktreeCreate.self, WorktreeList.self, WorktreeArchive.self, WorktreeRemove.self, WorktreeUnarchive.self,
        WorktreeUnmerged.self, WorktreeDirty.self]
}
