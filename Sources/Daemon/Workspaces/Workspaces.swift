import Core
import Foundation
import GitKit
import os

/// Workspaces are worktree records. Most are in the project's folder, with the repo's path as their path, and are a
/// set of tabs and agents with nothing of their own on disk. Several workspaces can share the folder. Workspaces from
/// older versions may still be git worktrees on their own branches. This type keeps the workspaces, the branches they
/// follow, and which projects' `.kelp.yaml` the user trusts (Scripts.swift).
final class Workspaces: Sendable {
    let root: URL
    let store: Store
    let remotes: Remotes
    let sessions: any WorkspaceSessions   // a workspace's agents pause, start and go with it
    let clients: Clients
    /// Makes reading the projects' workspaces and adding a missing first one a single step, because two syncs at the
    /// same time used to add two "Workspace 1".
    let workspaceLock = NSLock()   // held across git calls (a blocking run), so not the unfair lock
    /// The watch on each project's .git, by project, so workspaces follow the branch. It is nil once stopped, so
    /// nothing starts watching again.
    let heads = OSAllocatedUnfairLock<[String: HeadWatch]?>(initialState: [:])
    let headQueue = DispatchQueue(label: "kelp.heads")   // syncs one at a time, off every reader and the pool
    let trustLock = NSLock()   // guards each read-modify-write of trusted-configs.json
    let routines: Routines   // agents on a schedule, each in a workspace of its own
    let databases: Databases   // the projects' databases (db.*), what agents may do with them, and what agents ran
    let commitPlans: CommitPlans   // the commits agents proposed, until the window takes them
    let sweeps = WorktreeSweeps()   // worktree sizes per project, one sweep at a time, kept a moment
    /// Branches being made into workspaces ("repo/branch"), held until their record is saved. That way two workspaces
    /// made at once don't pick the same "ws-N", which git would refuse for the second.
    let making = OSAllocatedUnfairLock(initialState: Set<String>())

    init(root: URL, store: Store, remotes: Remotes, sessions: Sessions, clients: Clients) {
        self.root = root
        self.store = store
        self.remotes = remotes
        self.sessions = sessions
        self.clients = clients
        self.routines = Routines(store: store, sessions: sessions, clients: clients)
        self.commitPlans = CommitPlans(store: store)
        self.databases = Databases(
            store: store, sessions: sessions, watches: sessions.watches, remotes: remotes, offloads: sessions.offloads)
    }

    func notify(_ event: some RPCEvent, to only: Set<Int>? = nil) { clients.notify(event, to: only) }

    /// Makes the folder, or fails if anything is there already, so exactly one of two clones racing for one name gets
    /// it.
    static func claim(_ dest: String) -> Bool { mkdir(dest, 0o755) == 0 }

    /// The folder of the workspace a client named.
    func folder(_ worktreeId: String) throws -> String { try store.worktree(named: worktreeId).path }

    /// Returns the folder a project's worktrees go in. Its name is the project's name made safe for a folder ("../x"
    /// can't leave `worktrees/`) plus the project's id, so two projects with one name don't share a folder.
    /// `chosen` is the folder set in Settings › Git (`worktrees.folder`, with `~` for home). When it is set, the
    /// project's worktrees go in a subfolder named after the project there, where an editor or Finder finds them.
    static func worktreesDir(_ root: URL, _ repo: Repo, chosen: String? = nil) -> URL {
        let name = Git.slug(repo.name).replacingOccurrences(of: ".", with: "-")
        if let chosen = chosen?.trimmingCharacters(in: .whitespaces), !chosen.isEmpty {
            return URL(fileURLWithPath: (chosen as NSString).expandingTildeInPath).appendingPathComponent(name)
        }
        return root.appendingPathComponent("worktrees").appendingPathComponent(name + "-" + repo.id.prefix(8))
    }

    static let placeholderName = #"^Workspace \d+$"#

    func isMain(_ worktree: Worktree, _ repo: Repo) -> Bool { worktree.path == repo.path }

    /// Returns a branch group's branch as it is now. When the branch was renamed in its folder (`git branch -m`), the
    /// name in the record no longer exists, and closing the group would ask about nothing and then fail, so the
    /// folder's current branch is returned. A switch to another branch doesn't count, because that branch isn't the
    /// group's to delete.
    func branchNow(of worktree: Worktree, in repo: Repo) -> String {
        guard !Git.branchExists(repo.path, worktree.branch, remotes: remotes),
            let now = Log.store.attempt(
                "reading \(worktree.path)'s branch", { try Git.currentBranch(worktree.path, remotes: remotes) }),
            now != "HEAD"
        else {
            return worktree.branch
        }
        return now
    }

    /// Returns whether a group is one that a home seeded from Kelp's (`HomeSeed`) shares. Its folder is in Kelp's
    /// home, and an agent there may be at work in it. Closing the group here closes it only here.
    static func borrowed(_ path: String, seed: URL?) -> Bool {
        seed.map { path.hasPrefix($0.appendingPathComponent("worktrees").path + "/") } == true
    }

    /// Makes sure every project keeps at least one workspace, and that workspaces follow the branch checked out in the
    /// folder. `only` limits this to that project.
    func syncMainWorkspaces(only: String? = nil) throws {
        try workspaceLock.withLock { try syncWorkspaces(only: only) }
    }

    /// The caller holds `workspaceLock`.
    private func syncWorkspaces(only: String? = nil) throws {
        let all = try store.worktrees(repo: only)
        for repo in try store.repos() where only == nil || repo.id == only {
            let workspaces = all.filter { isMain($0, repo) }
            // A remote project's branch is read over ssh, so not on every sync, because an unreachable host would stall
            // each sync for its connect timeout. Its workspaces keep the branch they have, and git.status and similar
            // methods read the branch when asked.
            if remotes.of(repo.path) != nil, !workspaces.isEmpty { continue }
            // When the branch isn't read (git timed out, or the folder is away), the workspaces keep the branch they
            // have, not the base.
            let read = remotes.of(repo.path) == nil ? try? Git.currentBranch(repo.path, remotes: remotes) : nil
            let branch = read ?? repo.baseBranch
            if workspaces.isEmpty {
                try store.save(
                    Worktree(repoId: repo.id, branch: branch, path: repo.path, note: "Workspace 1", base: branch))
            }
            for worktree in workspaces where (read != nil && worktree.branch != branch) || worktree.note.isEmpty {
                try store.update(Worktree.self, worktree.id) {
                    if read != nil { $0.branch = branch }
                    if $0.note.isEmpty { $0.note = "Workspace 1" }   // was the project's "main" workspace
                }
            }
        }
    }

    /// Makes a new workspace in the project's folder at once, named "Workspace N" until its first prompt names it (see
    /// autoTitle).
    func createWorkspace(in repo: Repo) throws -> Worktree {
        // The branch is read before taking the lock, because a remote project's branch is read over ssh, and a host
        // that doesn't answer would hold up every project's sync until it timed out.
        let branch = (try? Git.currentBranch(repo.path, remotes: remotes)) ?? repo.baseBranch
        let worktree = try workspaceLock.withLock {   // the lock makes "Workspace N" count the workspaces there now
            try syncWorkspaces()   // names the project's first workspace, so the new one doesn't take "Workspace 1"
            let taken = Set(try store.worktrees(repo: repo.id).map(\.note))
            var number = 1
            while taken.contains("Workspace \(number)") { number += 1 }
            let worktree = Worktree(
                repoId: repo.id, branch: branch, path: repo.path, note: "Workspace \(number)", base: branch)
            try store.save(worktree)
            return worktree
        }
        notify(ChangedEvent.worktree)   // the coarse `event.changed`, since the record went out when it was written
        return worktree
    }

    /// Returns the next free name and branch, such as "Workspace 3" on branch "ws-3", so a workspace is made at once
    /// and renamed from its first prompt later (see autoTitle). The branch stays claimed (`making`) until `made` lets
    /// it go.
    func nextWorkspace(in repo: Repo) throws -> (name: String, branch: String) {
        let taken = Set(try store.worktrees(repo: repo.id).map(\.note))
        var number = 2
        while taken.contains("Workspace \(number)") || !claimed(repo, "ws-\(number)") { number += 1 }
        return ("Workspace \(number)", "ws-\(number)")
    }

    /// Claims `branch` for this create: true when the branch doesn't exist and no other create is making it.
    private func claimed(_ repo: Repo, _ branch: String) -> Bool {
        let checkouts = Git.checkouts(project: repo.path, folder: repo.path)   // a folder of repositories: any of them
        guard !checkouts.contains(where: { Git.branchExists($0.repo, branch, remotes: remotes) }) else { return false }
        return making.withLock { $0.insert(repo.id + "/" + branch).inserted }
    }

    private func made(_ repo: Repo, _ branches: [String]) {
        making.withLock { claims in for branch in branches { claims.remove(repo.id + "/" + branch) } }
    }

    /// Makes a workspace on a branch of its own, in a worktree of `repo`, as `asked` says. The branch is `branch`, or
    /// else "ws-N" or a name made from `note`, and it is made from `base`, or else from the project's base. It can also
    /// be an existing branch checked out as it is (`existing`), or a pull request's head (`pr`). What the project's
    /// .kelp.yaml links, clones and starts waits for the user's trust in that file.
    func createBranchWorkspace(in repo: Repo, _ asked: WorktreeCreate) throws -> WorktreeCreate.Result {
        let note = asked.note, pr = asked.pr, existing = asked.existing == true
        // A folder of repositories (`RepoKey`) gets the branch in each of them, side by side in one folder.
        let several = try branchRepos(repo, pr: pr, existing: existing)
        // A project opened without Git gets a plain sentence, not git's refusal.
        if several.isEmpty {
            do { _ = try Git.root(of: repo.path, remotes: remotes) } catch {
                throw RPCError.invalidParams("“\(repo.name)” isn't a Git repository, so it has no branches.")
            }
        }
        let auto = try nextWorkspace(in: repo)
        var claims = [auto.branch]
        defer { made(repo, claims) }
        var branch = try clientRef(asked.branch.flatMap { $0.isEmpty ? nil : $0 }) ?? auto.branch
        // A name given for a new workspace names its branch too, as a first prompt would (`nameBranch`), with "-2"
        // added when that is taken.
        if asked.branch == nil, pr == nil, let given = note?.trimmingCharacters(in: .whitespaces), !given.isEmpty,
            !Naming.slug(given).isEmpty
        {
            let wanted = sessions.branchPrefix + Naming.slug(given)
            var suffix = 2
            branch = wanted
            while !claimed(repo, branch) {
                branch = "\(wanted)-\(suffix)"
                suffix += 1
            }
            claims.append(branch)
        }
        if let pr {
            branch = try Git.fetchPullRequest(
                repo: repo.path, number: pr, wanted: asked.branch == nil ? nil : branch, remotes: remotes)
        }
        let base = try clientRef(asked.base.flatMap { $0.isEmpty ? nil : $0 }) ?? repo.baseBranch
        let into = Self.worktreesDir(root, repo, chosen: sessions.settings[SettingKeys.worktreesFolder])
        // A pull request's code, fetched now or found under the branch it starts from (`holdsPullRequest`), gets none
        // of the project's own files (.env). Nothing from .kelp.yaml runs on it until the user says so (below).
        let checksOut = existing || pr != nil
        let fromPR = pr != nil || Git.holdsPullRequest(repo.path, at: checksOut ? branch : base, remotes: remotes)
        let host = remotes.of(repo.path)
        let path =
            try host.map { try remoteWorktree(repo, $0, branch: branch, base: base, existing: checksOut) }
            ?? (several.isEmpty
                ? Git.addWorktree(
                    repo: repo.path, branch: branch, base: base, into: into, copyFiles: repo.copyFiles,
                    existing: checksOut, copying: !fromPR, remotes: remotes)
                : Git.addWorktrees(
                    project: repo.path, branch: branch, into: into, copyFiles: repo.copyFiles,
                    remotes: remotes))
        // Checking out "origin/x" makes a local "x" that follows it, so the workspace records "x".
        if existing, !Git.branchExists(repo.path, branch, remotes: remotes) {
            branch = branch.split(separator: "/", maxSplits: 1).last.map(String.init) ?? branch
        }
        var workspace = Worktree(
            repoId: repo.id, branch: branch, path: path, note: note ?? (asked.branch == nil ? auto.name : ""),
            base: base)
        workspace.madeBy = Sessions.asker
        try store.save(workspace)
        var result = WorktreeCreate.Result(worktree: workspace)
        // Everything .kelp.yaml does waits for the user's trust in this version of the file, not only `setup`. `tabs`
        // starts agents and `shared` links folders, and a freshly cloned repository wrote that file, not the user. The
        // file is checked and used from one read. A pull request brings code that the file's trust doesn't cover, such
        // as an install script by the pull request's author. So nothing runs on it until the user says so, nor on a
        // branch made on top of one (`fromPR`).
        let read = configAndTrust(repo.path), cfg = read.config, trusted = read.trusted && !fromPR
        if trusted, host == nil {   // Limit: a host's worktree gets no `shared` links or `clone` copies
            Git.linkShared(cfg.shared, repo: repo.path, worktree: path)
            for why in Git.cloneShared(cfg.clone, repo: repo.path, worktree: path) {
                Log.session.error(
                    ".kelp.yaml clone left out \(why, privacy: .public): the worktree is on another volume, or the path is busy"
                )
            }
        }
        if trusted {
            if asked.tabs != false {
                for tab in cfg.tabs {
                    do {
                        _ = try sessions.spawn(
                            cwd: path, manifest: sessions.setup.manifest(tab, command: nil), worktreeId: workspace.id)
                    } catch { Log.session.error(".kelp.yaml tab \(tab, privacy: .public) didn't start: \(error)") }
                }
            }
        }
        let asks = cfg.setup != nil || !cfg.tabs.isEmpty || !cfg.shared.isEmpty || !cfg.clone.isEmpty
        if asks, asked.setup != false, !trusted {
            result.setupNeedsTrust = true   // the app asks, then scripts.trust + scripts.run "setup"
        } else if let cmd = cfg.setup, asked.setup != false {
            var launch = Sessions.Launch()
            launch.title = "setup"
            let session = try sessions.spawn(
                cwd: path, manifest: .custom(cfg.shell(cmd)), worktreeId: workspace.id, launch)
            result.setupSession = session.id
        }
        notify(ChangedEvent.worktree)
        sessions.events.workspaceAdded(result.worktree)
        return result
    }

    /// Archives a workspace and keeps its folder, ignored files (.env, node_modules, builds) and all. Its agents pause,
    /// and unarchiving finds everything where it was. A project keeps at least one workspace.
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

    /// Removes the workspace and its agents. A workspace in the project's own folder leaves the folder as it is (a
    /// project keeps at least one workspace). A worktree's folder is removed too, and its branch with it, unless the
    /// branch has commits no other branch has (`dropCommits` allows that), the folder holds changes (`force` allows
    /// that), or the branch isn't the workspace's to delete (`keepBranch`, for a branch that was checked out there).
    func removeWorkspace(
        _ workspace: Worktree, _ repo: Repo, force: Bool, dropCommits drop: Bool, keepBranch: Bool = false
    ) throws {
        if isMain(workspace, repo) {
            guard try store.worktrees(repo: repo.id).filter({ isMain($0, repo) }).count > 1 else {
                throw RPCError.invalidParams("A project keeps at least one workspace; remove the project instead.")
            }
            sessions.discard(try store.sessions().filter { $0.worktreeId == workspace.id })
            try store.delete(workspace)
            notify(ChangedEvent.worktree)
            return
        }
        if Self.borrowed(workspace.path, seed: Paths.seed) {
            try sessions.pauseSessions(of: workspace.id)
            sessions.discard(try store.sessions().filter { $0.worktreeId == workspace.id })
            try store.delete(workspace)
            notify(ChangedEvent.worktree)
            return
        }
        let branch = keepBranch ? nil : branchNow(of: workspace, in: repo)
        // A remote project's folder is on its host, so the worktree is looked for there, by the path that its
        // stand-in folder here maps to.
        let host = remotes.of(repo.path)   // the project's host, since its worktrees are there too
        let there = remotes.of(workspace.path)?.path ?? workspace.path
        if try removeSeveral(workspace, repo, branch: branch, force: force, dropCommits: drop) { return }
        let exists =
            try host.map {
                String(
                    decoding: try $0.run("[ -e \(ShellQuote.word(there)) ] && echo yes || true"), as: UTF8.self
                )
                .hasPrefix("yes")
            }
            ?? FileManager.default.fileExists(atPath: workspace.path)
        if exists {
            // Refuse before anything stops. Then pause the workspace's agents, and only then remove it, checking
            // again, so an agent still writing can't have its work deleted under it.
            try Git.checkRemovable(
                repo: repo.path, path: workspace.path, branch: branch, force: force, dropCommits: drop,
                remotes: remotes)
            try sessions.pauseSessions(of: workspace.id)
            try Git.removeWorktree(
                repo: repo.path, path: workspace.path, branch: branch, force: force, dropCommits: drop,
                remotes: remotes)
        } else {
            try sessions.pauseSessions(of: workspace.id)
            // The folder is gone already (a removal that stopped after the Trash), but git's record and the branch
            // mustn't stay behind.
            try Git.forgetWorktree(
                repo: repo.path, path: workspace.path, branch: branch, dropCommits: drop, remotes: remotes)
        }
        // The turn refs of the workspace's sessions live in the project's repository, so they are dropped there once
        // the folder is gone. Not before, because a removal that fails keeps the workspace, and its turns keep their
        // snapshots.
        for session in try store.sessions() where session.worktreeId == workspace.id {
            sessions.turns.dropRefs(of: session.id, in: repo.path)
        }
        sessions.discard(try store.sessions().filter { $0.worktreeId == workspace.id })
        try store.delete(workspace)
        sweeps.forget(repo.id)   // so the project's card stops listing the worktree now
        if host != nil, remotes.of(workspace.path) != nil {   // the stand-in folder here holds only the marker
            Log.store.attempt("removing a remote worktree's folder here") {
                try FileManager.default.removeItem(atPath: workspace.path)
            }
        }
        notify(ChangedEvent.worktree)
    }

    /// Moves the project's other worktrees at `paths` (ones Kelp didn't make) to the Trash. A worktree is kept when
    /// it's in use, holds work, or isn't one of them, and the result says why it was kept. A removed worktree's branch
    /// goes too if another branch has its commits.
    func removeWorktrees(_ paths: [String], of repo: Repo) throws -> RepoRemoveWorktrees.Result {
        let linked = try Git.linkedWorktrees(repo.path, remotes: remotes)
        let ours = try RepoWorktreeSizes.ours(store, repo)
        var out = RepoRemoveWorktrees.Result(removed: [], kept: [:])
        defer { sweeps.forget(repo.id) }   // forgets the last sweep, whose sizes still list what goes here
        // A paused agent comes back where it last worked, so its folder is as much in use as a running agent's.
        let stored = try store.sessions().filter { $0.status != .exited }.map(\.currentDir)
        let inUse = sessions.live.all.map(\.snapshot.currentDir) + stored
        for path in paths {
            guard let worktree = linked.first(where: { $0.path == path }), !ours.contains(RepoWorktreeSizes.real(path))
            else {
                out.kept[path] = "Not one of the project's other worktrees."
                continue
            }
            // A worktree an agent just made has nothing in it yet, so it looks clean, and its folder would go from
            // under the agent.
            let real = RepoWorktreeSizes.real(path) + "/"
            if inUse.contains(where: { (RepoWorktreeSizes.real($0) + "/").hasPrefix(real) }) {
                out.kept[path] = "An agent works in it."
                continue
            }
            do {
                // git removes a worktree whose commits are on no branch (a detached HEAD), which leaves those commits
                // to `git gc`. When they can't be counted, the worktree is kept too, and the catch says why.
                if case let commits = try Git.commitsOnNoBranch(path, remotes: remotes), commits > 0 {
                    out.kept[path] =
                        "It has \(commits) commit\(commits == 1 ? "" : "s") on no branch (a detached HEAD)."
                    continue
                }
                // A worktree with changes, untracked files or a lock is kept. Otherwise the folder goes to the Trash
                // with its ignored files (.env, a local database), which `git worktree remove` would delete for good.
                // Its branch stays here and is handled below.
                try Git.removeWorktree(repo: repo.path, path: path, branch: nil, force: false, remotes: remotes)
                // `branch -d` deletes the branch only if its commits are on another branch.
                if let branch = worktree.branch, Git.isRevision(branch) {
                    _ = Log.store.attempt("deleting merged branch \(branch)") {
                        try Git.run(["branch", "-d", branch], cwd: repo.path, remotes: remotes)
                    }
                }
                out.removed.append(path)
            } catch let error as GitError { out.kept[path] = error.message } catch {
                out.kept[path] = error.localizedDescription
            }
        }
        return out
    }
}
