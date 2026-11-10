import Foundation

// Projects (repos), their workspaces (worktrees: workspaces in the project's folder, or git worktrees of their own) and the
// sessions in them. Results are the records (Repo, Worktree, Session) or what's noted.

/// A folder in a repository adds the repository. One outside any: `init` true runs `git init` there, false adds the
/// folder as it is (no git), and without `init` the call fails with `notARepository` (the app asks which).
public struct RepoAdd: RPCMethod {
    public static let name = "repo.add"
    public typealias Result = Repo
    public var path: String, name: String?, `init`: Bool?
    public init(path: String, name: String? = nil, `init`: Bool? = nil) {
        self.path = path
        self.name = name
        self.`init` = `init`
    }
    public static let notARepository = RPCError(
        code: -32003,
        message:
            "Not a Git repository: add it with init true (git init there) or false (as it is, without git); kelp repo add --init or --no-git."
    )
}
/// All projects.
public struct RepoList: RPCMethod {
    public static let name = "repo.list"
    public typealias Result = [Repo]
    public init() {}
}
/// The workspace of the chats outside any project (No Project), a plain folder made the first time; each agent started on it works in a folder of its own inside.
public struct ScratchEnsure: InternalMethod {
    public static let name = "scratch.ensure"
    public typealias Result = Worktree
    public init() {}
}
/// The project's folder moved: the project and its workspaces point at `path`.
public struct RepoRelocate: RPCMethod {
    public static let name = "repo.relocate"
    public typealias Result = Repo
    public var id: String, path: String
    public init(id: String, path: String) {
        self.id = id
        self.path = path
    }
}
/// The project's own name; an empty one gives back its folder's. Its path, workspaces and agents stay as they are.
public struct RepoRename: RPCMethod {
    public static let name = "repo.rename"
    public typealias Result = Repo
    public var id: String, name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
/// Its workspaces go with it, and their agents stop.
public struct RepoRemove: RPCMethod {
    public static let name = "repo.remove"
    public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}

/// A new group in the project: a screen of its own in the project's folder.
public struct WorkspaceCreate: RPCMethod {
    public static let name = "workspace.create"
    public typealias Result = Worktree
    public var repoId: String
    public init(repoId: String) { self.repoId = repoId }
}
/// A git worktree on a new `branch` from `base`; `tabs`/`setup` false skip .kelp.yaml's. Adds `setupNeedsTrust` or `setupSession`.
public struct WorktreeCreate: RPCMethod {
    public static let name = "worktree.create"
    public var repoId: String, branch: String?, base: String?, note: String?, tabs: Bool?, setup: Bool?
    /// `branch` is there already (a local one, or "origin/x"): checked out as it is, not made from `base`.
    public var existing: Bool?
    /// A pull request's number: its head is fetched into `branch` (else "pr-N") and checked out.
    public var pr: Int?
    public init(
        repoId: String, branch: String? = nil, base: String? = nil, note: String? = nil, tabs: Bool? = nil,
        setup: Bool? = nil,
        existing: Bool? = nil, pr: Int? = nil
    ) {
        self.repoId = repoId
        self.branch = branch
        self.base = base
        self.note = note
        self.tabs = tabs
        self.setup = setup
        self.existing = existing
        self.pr = pr
    }
    /// The worktree's own fields, and beside them what its .kelp.yaml setup needs.
    public struct Result: Codable, Sendable, Equatable {
        public var worktree: Worktree, setupNeedsTrust: Bool?, setupSession: String?
        public init(worktree: Worktree, setupNeedsTrust: Bool? = nil, setupSession: String? = nil) {
            self.worktree = worktree
            self.setupNeedsTrust = setupNeedsTrust
            self.setupSession = setupSession
        }
        private enum Extra: String, CodingKey { case setupNeedsTrust, setupSession }
        public init(from decoder: Decoder) throws {
            worktree = try Worktree(from: decoder)
            let container = try decoder.container(keyedBy: Extra.self)
            setupNeedsTrust = try container.decodeIfPresent(Bool.self, forKey: .setupNeedsTrust)
            setupSession = try container.decodeIfPresent(String.self, forKey: .setupSession)
        }
        public func encode(to encoder: Encoder) throws {
            try worktree.encode(to: encoder)
            var container = encoder.container(keyedBy: Extra.self)
            try container.encodeIfPresent(setupNeedsTrust, forKey: .setupNeedsTrust)
            try container.encodeIfPresent(setupSession, forKey: .setupSession)
        }
    }
}
/// Workspaces, of project `repoId` when given; `archived` lists those instead.
public struct WorktreeList: RPCMethod {
    public static let name = "worktree.list"
    public typealias Result = [Worktree]
    public var repoId: String?, archived: Bool?
    public init(repoId: String? = nil, archived: Bool? = nil) {
        self.repoId = repoId
        self.archived = archived
    }
}
/// Out of sight with its folder kept: its agents pause.
public struct WorktreeArchive: RPCMethod {
    public static let name = "worktree.archive"
    public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}
/// `force`: uncommitted changes go too; `dropCommits`: so do commits on no other branch.
public struct WorktreeRemove: RPCMethod {
    public static let name = "worktree.remove"
    public typealias Result = Done
    public var id: String, force: Bool?, dropCommits: Bool?
    public init(id: String, force: Bool? = nil, dropCommits: Bool? = nil) {
        self.id = id
        self.force = force
        self.dropCommits = dropCommits
    }
}
/// Brings an archived workspace back.
public struct WorktreeUnarchive: RPCMethod {
    public static let name = "worktree.unarchive"
    public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}
/// → how many commits on its branch no other branch or remote has (lost if it's deleted).
public struct WorktreeUnmerged: RPCMethod {
    public static let name = "worktree.unmerged"
    public typealias Result = Int
    public var id: String
    public init(id: String) { self.id = id }
}
/// Whether its folder has uncommitted changes.
public struct WorktreeDirty: RPCMethod {
    public static let name = "worktree.dirty"
    public typealias Result = Bool
    public var id: String
    public init(id: String) { self.id = id }
}

/// Clones `url` into a new folder in `parent` (`folder`, else named after the repository) → the added project; progress
/// comes as `event.clone` {id, line}.
public struct RepoClone: RPCMethod {
    public static let name = "repo.clone"
    public typealias Result = Repo
    public var url: String, parent: String, folder: String?, id: String?
    public static var timeout: TimeInterval? { nil }   // a big repository takes as long as it takes; Cancel stops it
    public init(url: String, parent: String, folder: String? = nil, id: String? = nil) {
        self.url = url
        self.parent = parent
        self.folder = folder
        self.id = id
    }

    /// "git@github.com:me/app.git", "https://gitlab.com/me/app" → "app".
    public static func folderName(_ url: String) -> String {
        var name =
            url.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { "/:".contains($0) }).last.map(
                String.init) ?? ""
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        return name
    }
}
/// Stops clone `id` (its half-made folder is removed).
public struct RepoCloneCancel: RPCMethod {
    public static let name = "repo.cloneCancel"
    public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}

/// The project's other git worktrees (agents' `.claude/worktrees/…`, older Kelp workspaces) and the disk each takes,
/// biggest first: they grow with every build and nothing in the folder itself shows it.
public struct RepoWorktreeSizes: InternalMethod {
    public static let name = "repo.worktreeSizes"
    public struct Item: Codable, Sendable, Equatable {
        public var path: String, bytes: Int
        /// Nothing uncommitted or untracked, not locked, not one of Kelp's workspaces (those go with Delete Workspace).
        public var removable: Bool
        public init(path: String, bytes: Int, removable: Bool) {
            self.path = path
            self.bytes = bytes
            self.removable = removable
        }
    }
    public typealias Result = [Item]
    public var id: String
    public init(id: String) { self.id = id }
}

/// Removes those of `paths` that are still clean, as `git worktree remove` without --force does (one with changes,
/// untracked files or a lock stays), each with its branch when that branch's commits are on another one too.
public struct RepoRemoveWorktrees: InternalMethod {
    public static let name = "repo.removeWorktrees"
    public struct Result: Codable, Sendable {
        public var removed: [String], kept: [String: String]   // kept: path → why
        public init(removed: [String], kept: [String: String]) {
            self.removed = removed
            self.kept = kept
        }
    }
    public var id: String, paths: [String]
    public init(id: String, paths: [String]) {
        self.id = id
        self.paths = paths
    }
}

/// The workspace's name.
public struct WorktreeNote: RPCMethod {
    public static let name = "worktree.note"
    public typealias Result = Done
    public var id: String, note: String
    public init(id: String, note: String) {
        self.id = id
        self.note = note
    }
}
