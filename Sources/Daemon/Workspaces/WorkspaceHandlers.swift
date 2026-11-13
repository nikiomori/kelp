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
        try workspaces.removeWorkspace(workspace, repo, force: force == true, dropCommits: dropCommits == true)
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

extension WorktreeNote: Handled {
    func handle(_ workspaces: Workspaces) throws -> Done {
        guard try workspaces.store.update(Worktree.self, id, { $0.note = note }) != nil else {
            throw RPCError.invalidParams("no worktree")
        }
        workspaces.notify(ChangedEvent.worktree)
        return Done()
    }
}

extension RepoWorktreeSizes: Handled {
    func handle(_ workspaces: Workspaces) throws -> [Item] {
        guard let repo = try workspaces.store.repo(id) else { throw RPCError.invalidParams("no repo") }
        guard workspaces.remotes.of(repo.path) == nil else { return [] }   // their disk is on the host
        let ours = try Self.ours(workspaces.store, repo)
        return try Git.linkedWorktrees(repo.path, remotes: workspaces.remotes).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }.map { worktree in
            Item(
                path: worktree.path, bytes: Self.du(worktree.path),
                removable: !worktree.locked && !ours.contains(Self.real(worktree.path))
                    && (try? Git.isDirty(worktree.path, remotes: workspaces.remotes)) == false
                    && Git.commitsOnNoBranch(worktree.path, remotes: workspaces.remotes) == 0)
        }.sorted { $0.bytes > $1.bytes }
    }

    /// Kelp's own worktree workspaces (from older versions): git prints real paths, the store keeps them as created.
    static func ours(_ store: Store, _ repo: Repo) throws -> Set<String> {
        Set(try store.worktrees(repo: repo.id).map { real($0.path) })
    }
    static func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }

    /// Blocks on disk as `du` counts them (16 GB of build products: about a second); unreadable files leave out only themselves.
    static func du(_ path: String) -> Int {
        let out =
            (try? Subprocess.output(["/usr/bin/du", "-sk", path], cwd: path, ok: [0, 1])).map {
                String(decoding: $0, as: UTF8.self)
            } ?? ""
        return (Int(out.prefix { $0.isNumber }) ?? 0) * 1024
    }
}

extension RepoRemoveWorktrees: Handled {
    var notForAgents: String? { "Only the user clears a project's worktrees." }
    func handle(_ workspaces: Workspaces) throws -> Result {
        guard let repo = try workspaces.store.repo(id) else { throw RPCError.invalidParams("no repo") }
        return try workspaces.removeWorktrees(paths, of: repo)
    }
}

extension Methods {
    static let workspaceMethods: [any Answered.Type] = [
        RepoAdd.self, RepoList.self, ScratchEnsure.self, RepoRelocate.self, RepoRename.self, RepoRemove.self,
        WorkspaceCreate.self, WorktreeCreate.self, WorktreeList.self, WorktreeArchive.self, WorktreeRemove.self,
        WorktreeUnarchive.self, WorktreeUnmerged.self, WorktreeDirty.self, WorktreeNote.self, RepoWorktreeSizes.self,
        RepoRemoveWorktrees.self
    ]
}
