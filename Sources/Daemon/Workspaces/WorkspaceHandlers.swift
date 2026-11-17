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
        do {
            try workspaces.store.save(repo)
        } catch {
            // Added meanwhile (two adds of one folder at once): that project, as when it was there before.
            if let added = try workspaces.store.repos().first(where: { $0.path == root }) { return added }
            throw error
        }
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
        guard let old = try workspaces.store.repo(id)?.path else { throw RPCError.noProject(id) }
        let root = try Git.root(of: path, remotes: workspaces.remotes)
        // Its path only, in one write: the copy read before git ran would put back a rename made meanwhile.
        guard let repo = try workspaces.store.update(Repo.self, id, { $0.path = root }) else {
            throw RPCError.invalidParams("That project was removed meanwhile.")
        }
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
        guard var repo = try workspaces.store.repo(id) else { throw RPCError.noProject(id) }
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
    var fence: Fence { Fence(ends: .project(id), notForAgents: "Only the user removes a project from Kelp.") }
    func handle(_ workspaces: Workspaces) throws -> Done {
        guard let repo = try workspaces.store.repo(id) else { throw RPCError.noProject(id) }
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
    var fence: Fence { Fence(makesInProject: repoId) }
    func handle(_ workspaces: Workspaces) throws -> Worktree {
        guard let repo = try workspaces.store.repo(repoId) else { throw RPCError.noProject(repoId) }
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
    var fence: Fence { Fence(makesInProject: repoId) }
    func handle(_ workspaces: Workspaces) throws -> Result {
        guard let repo = try workspaces.store.repo(repoId) else { throw RPCError.noProject(repoId) }
        return try workspaces.createBranchWorkspace(in: repo, self)
    }
}

/// Only reads: workspaces follow their folders' branches as they change (`watchHeads`), not when someone lists them.
extension WorktreeList: Handled {
    func handle(_ workspaces: Workspaces) throws -> [Worktree] {
        try workspaces.store.worktrees(repo: repoId).filter { archived == true || !$0.archived }
    }
}

extension WorktreeArchive: Handled {
    var fence: Fence { Fence(ends: .workspace(id)) }
    func handle(_ workspaces: Workspaces) throws -> Done {
        guard let workspace = try workspaces.store.worktree(id), let repo = try workspaces.store.repo(workspace.repoId)
        else {
            throw RPCError.noWorkspace(id)
        }
        try workspaces.archive(workspace, repo)
        return Done()
    }
}

extension WorktreeRemove: Handled {
    var fence: Fence {
        Fence(
            ends: .workspace(id),
            notForAgents: force == true || dropCommits == true
                ? "Only the user removes a workspace with its changes or commits." : nil)
    }
    func handle(_ workspaces: Workspaces) throws -> Done {
        guard let workspace = try workspaces.store.worktree(id), let repo = try workspaces.store.repo(workspace.repoId)
        else {
            throw RPCError.noWorkspace(id)
        }
        try workspaces.removeWorkspace(workspace, repo, force: force == true, dropCommits: dropCommits == true)
        workspaces.databases.dropCopies(of: workspace)   // its own copies of the project's databases go with it
        return Done()
    }
}

extension WorktreeUnarchive: Handled {
    func handle(_ workspaces: Workspaces) throws -> Done {
        guard try workspaces.store.update(Worktree.self, id, { $0.archived = false }) != nil else {
            throw RPCError.noWorkspace(id)
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

extension WorktreeNote: Handled {
    func handle(_ workspaces: Workspaces) throws -> Done {
        guard try workspaces.store.update(Worktree.self, id, { $0.note = note }) != nil else {
            throw RPCError.noWorkspace(id)
        }
        workspaces.notify(ChangedEvent.worktree)
        return Done()
    }
}

extension RepoWorktreeSizes: Handled {
    func handle(_ workspaces: Workspaces) throws -> [Item] {
        guard let repo = try workspaces.store.repo(id) else { throw RPCError.noProject(id) }
        return try Self.sizes(of: repo, workspaces)
    }

    /// One sweep of a project at a time, its answer given again for a moment (`WorktreeSweeps`): every hover card of
    /// the project asks. `again`: swept now (a Disk Usage measure, which Measure Again and a removal ask for).
    static func sizes(of repo: Repo, _ workspaces: Workspaces, again: Bool = false) throws -> [Item] {
        guard workspaces.remotes.of(repo.path) == nil else { return [] }   // their disk is on the host
        return try workspaces.sweeps.sizes(of: repo.id, again: again) { try sweep(repo, workspaces) }
    }

    /// A `du` and two git for each worktree, one after another.
    private static func sweep(_ repo: Repo, _ workspaces: Workspaces) throws -> [Item] {
        let ours = try Self.ours(workspaces.store, repo)
        return try Git.linkedWorktrees(repo.path, remotes: workspaces.remotes).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }.map { worktree in
            Item(
                path: worktree.path, bytes: try Self.du(worktree.path),
                removable: !worktree.locked && !ours.contains(Self.real(worktree.path))
                    && (try? Git.isDirty(worktree.path, remotes: workspaces.remotes)) == false
                    && (try? Git.commitsOnNoBranch(worktree.path, remotes: workspaces.remotes)) == 0)
        }.sorted { $0.bytes > $1.bytes }
    }

    /// Kelp's own worktree workspaces (from older versions): git prints real paths, the store keeps them as created.
    static func ours(_ store: Store, _ repo: Repo) throws -> Set<String> {
        Set(try store.worktrees(repo: repo.id).map { real($0.path) })
    }
    static func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }

    /// Blocks on disk as `du` counts them (16 GB of build products: about a second); unreadable files leave out only
    /// themselves. A `du` that failed throws (`DiskUsage.du`): it isn't 0 bytes. The one line's number, whatever the
    /// path is spelled with (a newline in it would split the line).
    static func du(_ path: String) throws -> Int { try DiskUsage.du([path]).values.first ?? 0 }
}

extension RepoRemoveWorktrees: Handled {
    var fence: Fence { Fence(notForAgents: "Only the user clears a project's worktrees.") }
    func handle(_ workspaces: Workspaces) throws -> Result {
        guard let repo = try workspaces.store.repo(id) else { throw RPCError.noProject(id) }
        return try workspaces.removeWorktrees(paths, of: repo)
    }
}

extension RepoDiskUsage: Handled {
    func handle(_ disk: DiskUsage) throws -> Result {
        guard let repo = try disk.workspaces.store.repo(id) else { throw RPCError.noProject(id) }
        return try disk.measure(repo)
    }
}

extension RepoDiskTrash: Handled {
    var fence: Fence { Fence(notForAgents: "Only the user clears a project's disk.") }
    func handle(_ disk: DiskUsage) throws -> Result {
        guard let repo = try disk.workspaces.store.repo(id) else { throw RPCError.noProject(id) }
        return try disk.trash(paths, of: repo)
    }
}

extension Methods {
    static let workspaceMethods: [any Answered.Type] = [
        RepoAdd.self, RepoList.self, ScratchEnsure.self, RepoRelocate.self, RepoRename.self, RepoRemove.self,
        WorkspaceCreate.self, WorktreeCreate.self, WorktreeList.self, WorktreeArchive.self, WorktreeRemove.self,
        WorktreeUnarchive.self, WorktreeUnmerged.self, WorktreeDirty.self, WorktreeNote.self, RepoWorktreeSizes.self,
        RepoRemoveWorktrees.self, RepoDiskUsage.self, RepoDiskTrash.self
    ]
}
