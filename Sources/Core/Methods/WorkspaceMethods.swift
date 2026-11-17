import Foundation

// Projects (repos), their workspaces (worktrees, which are workspaces in the project's folder or git worktrees of their
// own) and the sessions in them. Results are the records (Repo, Worktree, Session) unless noted.

/// Adds a project. A folder inside a repository adds the repository. For a folder outside any repository, `init` true
/// runs `git init` there, false adds the folder as it is (no git), and without `init` the call fails with
/// `notARepository`, so the app can ask which.
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
/// Lists all projects.
public struct RepoList: RPCMethod {
    public static let name = "repo.list"
    public typealias Result = [Repo]
    public init() {}
}
/// Returns the workspace for chats outside any project (No Project), a plain folder made the first time. Each agent
/// started there works in a folder of its own inside it.
public struct ScratchEnsure: InternalMethod {
    public static let name = "scratch.ensure"
    public typealias Result = Worktree
    public init() {}
}
/// Records that the project's folder moved, so the project and its workspaces point at `path`.
public struct RepoRelocate: RPCMethod {
    public static let name = "repo.relocate"
    public typealias Result = Repo
    public var id: String, path: String
    public init(id: String, path: String) {
        self.id = id
        self.path = path
    }
}
/// Renames the project. An empty name gives it back its folder's name. Its path, workspaces and agents stay as they
/// are.
public struct RepoRename: RPCMethod {
    public static let name = "repo.rename"
    public typealias Result = Repo
    public var id: String, name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
/// Removes the project. Its workspaces go with it, and their agents stop.
public struct RepoRemove: RPCMethod {
    public static let name = "repo.remove"
    public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}

/// Makes a new group in the project, a workspace of its own in the project's folder.
public struct WorkspaceCreate: RPCMethod {
    public static let name = "workspace.create"
    public typealias Result = Worktree
    public var repoId: String
    public init(repoId: String) { self.repoId = repoId }
}
/// Makes a git worktree on a new `branch` from `base`. `tabs` or `setup` set to false skips the tabs or the setup of
/// .kelp.yaml. The result adds `setupNeedsTrust` or `setupSession`.
public struct WorktreeCreate: RPCMethod {
    public static let name = "worktree.create"
    public var repoId: String, branch: String?, base: String?, note: String?, tabs: Bool?, setup: Bool?
    /// True when `branch` exists already (a local branch, or "origin/x"), so it is checked out as it is and not made
    /// from `base`.
    public var existing: Bool?
    /// A pull request's number. Its head is fetched into `branch` (or else "pr-N") and checked out.
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
    /// The worktree's own fields, plus what its .kelp.yaml setup needs.
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
/// Lists the workspaces, of project `repoId` when given. With `archived`, it lists the archived ones instead.
public struct WorktreeList: RPCMethod {
    public static let name = "worktree.list"
    public typealias Result = [Worktree]
    public var repoId: String?, archived: Bool?
    public init(repoId: String? = nil, archived: Bool? = nil) {
        self.repoId = repoId
        self.archived = archived
    }
}
/// Archives a workspace: it goes out of sight with its folder kept, and its agents pause.
public struct WorktreeArchive: RPCMethod {
    public static let name = "worktree.archive"
    public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}
/// Removes a workspace. With `force`, uncommitted changes go too. With `dropCommits`, so do commits that are on no
/// other branch.
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
/// Returns how many commits on the workspace's branch no other branch or remote has, which would be lost if it were
/// deleted.
public struct WorktreeUnmerged: RPCMethod {
    public static let name = "worktree.unmerged"
    public typealias Result = Int
    public var id: String
    public init(id: String) { self.id = id }
}
/// Returns whether the workspace's folder has uncommitted changes.
public struct WorktreeDirty: RPCMethod {
    public static let name = "worktree.dirty"
    public typealias Result = Bool
    public var id: String
    public init(id: String) { self.id = id }
}

/// Clones `url` into a new folder in `parent` (named `folder`, or else after the repository) and returns the added
/// project. Progress comes as `event.clone` {id, line}.
public struct RepoClone: RPCMethod {
    public static let name = "repo.clone"
    public typealias Result = Repo
    public var url: String, parent: String, folder: String?, id: String?
    public static var timeout: TimeInterval? { nil }   // A big repository takes as long as it takes; Cancel stops it.
    public init(url: String, parent: String, folder: String? = nil, id: String? = nil) {
        self.url = url
        self.parent = parent
        self.folder = folder
        self.id = id
    }

    /// Returns the folder name for a clone URL: "git@github.com:me/app.git" or "https://gitlab.com/me/app" gives
    /// "app".
    public static func folderName(_ url: String) -> String {
        var name =
            url.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { "/:".contains($0) }).last.map(
                String.init) ?? ""
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        return name
    }
}
/// Stops clone `id` and removes its half-made folder.
public struct RepoCloneCancel: RPCMethod {
    public static let name = "repo.cloneCancel"
    public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}

/// Returns the project's other git worktrees (agents' `.claude/worktrees/…`, older Kelp workspaces) and the disk space
/// each takes, biggest first. They grow with every build, and nothing in the folder itself shows it.
public struct RepoWorktreeSizes: InternalMethod {
    public static let name = "repo.worktreeSizes"
    public struct Item: Codable, Sendable, Equatable {
        public var path: String, bytes: Int
        /// True when the worktree has nothing uncommitted or untracked, isn't locked, and isn't one of Kelp's
        /// workspaces (those go with Delete Workspace).
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

/// Removes the worktrees in `paths` that are still clean, as `git worktree remove` without --force does, so a worktree
/// with changes, untracked files or a lock stays. Each goes with its branch when that branch's commits are on another
/// branch too.
public struct RepoRemoveWorktrees: InternalMethod {
    public static let name = "repo.removeWorktrees"
    public struct Result: Codable, Sendable {
        public var removed: [String], kept: [String: String]   // `kept` maps path → reason.
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

/// Returns what the project takes on this Mac, biggest first: what git ignores in its folder and its other worktrees,
/// each worktree's builds separately, Xcode's DerivedData for it, Claude Code's chats there, and the files git tracks.
/// A remote project's sizes are measured on its host, where there is no DerivedData.
public struct RepoDiskUsage: InternalMethod {
    public static let name = "repo.diskUsage"
    /// What a part is, which says whether removing it costs anything.
    public enum What: String, Codable, Sendable, CaseIterable {
        /// A build's output or a package manager's folder (`.build`, `node_modules`, DerivedData), which the next
        /// build makes again.
        case build
        /// Something else git ignores (`dist`, `.env`, a local database), whose value only the user knows.
        case ignored
        /// Another git worktree, not counting its builds. It is `removable` when nothing in it exists only there.
        case worktree
        /// Claude Code's conversations in the project's folders. They belong to Claude Code, so Kelp leaves them.
        case chats
        /// What git tracks, including `.git`.
        case files

        /// True when the part is safe to remove without asking what it is.
        public var rebuilds: Bool { self == .build }
        /// True when Kelp never offers to remove the part.
        public var leftAlone: Bool { self == .chats || self == .files }
    }
    public struct Item: Codable, Sendable, Equatable {
        public var path: String, bytes: Int, what: What
        /// True when Kelp may move the part to the Trash (`repo.diskTrash`).
        public var removable: Bool
        /// The other worktree the part is in. nil in the project's folder.
        public var worktree: String?
        public init(path: String, bytes: Int, what: What, removable: Bool, worktree: String? = nil) {
            self.path = path
            self.bytes = bytes
            self.what = what
            self.removable = removable
            self.worktree = worktree
        }
    }
    public typealias Result = [Item]
    public var id: String
    public static var timeout: TimeInterval? { 600 }   // The first du over a big tree can take that long.
    public init(id: String) { self.id = id }
}

/// Moves the paths in `paths` that `repo.diskUsage` lists as removable to the Trash. A worktree goes the way
/// `repo.removeWorktrees` removes it (kept if it holds work), and anything else only while git still ignores it. A
/// remote project's paths go into its `.git/kelp-trash` on the host, kept for a week. Each kept path says why.
public struct RepoDiskTrash: InternalMethod {
    public static let name = "repo.diskTrash"
    public typealias Result = RepoRemoveWorktrees.Result
    public var id: String, paths: [String]
    public init(id: String, paths: [String]) {
        self.id = id
        self.paths = paths
    }
}

/// Sets the workspace's name.
public struct WorktreeNote: RPCMethod {
    public static let name = "worktree.note"
    public typealias Result = Done
    public var id: String, note: String
    public init(id: String, note: String) {
        self.id = id
        self.note = note
    }
}
