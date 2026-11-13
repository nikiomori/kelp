import Core
import Foundation
import GitKit
import os

/// Workspaces are worktree records. Most are in the project's folder (their path is the repo path): a set of
/// tabs and agents, nothing on disk. Several workspaces can share the folder. Workspaces from older versions may still be
/// git worktrees on their own branches. This keeps the workspaces, the branches they follow, and which projects' `.kelp.yaml`
/// the user trusts (Scripts.swift).
final class Workspaces: Sendable {
    let root: URL
    let store: Store
    let remotes: Remotes
    let sessions: Sessions   // a workspace's agents pause, start and go with it
    let clients: Clients
    /// Reading the projects' workspaces and adding the missing first one is one step: two syncs at once added two "Workspace 1".
    let workspaceLock = NSLock()   // held across git calls (a blocking run), so not the unfair lock
    /// By project: its .git, for workspaces to follow the branch. nil once stopped: nothing starts watching again.
    let heads = OSAllocatedUnfairLock<[String: HeadWatch]?>(initialState: [:])
    let headQueue = DispatchQueue(label: "kelp.heads")   // syncs one at a time, off every reader and the pool
    let trustLock = NSLock()   // trusted-configs.json: read-modify-write under it
    let routines: Routines   // agents on a schedule, each in a workspace of its own
    let databases: Databases   // their projects' databases (db.*): what agents may do with them, what they ran
    /// The commits agents proposed (`kelp commit add`), by workspace, until the window takes them: in memory, as a
    /// message being written is.
    let commitPlans = OSAllocatedUnfairLock(initialState: [String: [PlannedCommit]]())

    init(root: URL, store: Store, remotes: Remotes, sessions: Sessions, clients: Clients) {
        self.root = root
        self.store = store
        self.remotes = remotes
        self.sessions = sessions
        self.clients = clients
        self.routines = Routines(store: store, sessions: sessions, clients: clients)
        self.databases = Databases(
            store: store, sessions: sessions, watches: sessions.watches, remotes: remotes, offloads: sessions.offloads)
    }

    func notify(_ event: some RPCEvent, to only: Set<Int>? = nil) { clients.notify(event, to: only) }

    /// Makes the folder, or fails if anything is there already: of two clones racing for one name, exactly one gets it.
    static func claim(_ dest: String) -> Bool { mkdir(dest, 0o755) == 0 }

    /// The folder of the workspace a client named.
    func folder(_ worktreeId: String) throws -> String { try store.worktree(named: worktreeId).path }

    /// Where a project's worktrees go: its name made safe for a folder ("../x" can't leave `worktrees/`) and its id, so two
    /// projects with one name don't share a folder.
    /// `chosen`: the folder set in Settings › Git (`worktrees.folder`, `~` for home): the project's go in a subfolder named
    /// after it there, where an editor or Finder finds them.
    static func worktreesDir(_ root: URL, _ repo: Repo, chosen: String? = nil) -> URL {
        let name = Git.slug(repo.name).replacingOccurrences(of: ".", with: "-")
        if let chosen = chosen?.trimmingCharacters(in: .whitespaces), !chosen.isEmpty {
            return URL(fileURLWithPath: (chosen as NSString).expandingTildeInPath).appendingPathComponent(name)
        }
        return root.appendingPathComponent("worktrees").appendingPathComponent(name + "-" + repo.id.prefix(8))
    }

    static let placeholderName = #"^Workspace \d+$"#

    func isMain(_ worktree: Worktree, _ repo: Repo) -> Bool { worktree.path == repo.path }

    /// A branch group's branch as it is: renamed in its folder (`git branch -m`), what the record says no longer exists, and
    /// closing it would ask about nothing and then fail. A switch to another branch doesn't count: that one isn't the group's to delete.
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

    /// A group a home seeded from Kelp's (`HomeSeed`) shares: its folder is in Kelp's home, and an agent there may be at work in
    /// it. Closing it here closes it here.
    static func borrowed(_ path: String, seed: URL?) -> Bool {
        seed.map { path.hasPrefix($0.appendingPathComponent("worktrees").path + "/") } == true
    }

    /// Every project keeps at least one workspace; workspaces follow the folder's checked-out branch. `only`: that
    /// project's.
    func syncMainWorkspaces(only: String? = nil) throws {
        try workspaceLock.withLock { try syncWorkspaces(only: only) }
    }

    /// The caller holds `workspaceLock`.
    private func syncWorkspaces(only: String? = nil) throws {
        let all = try store.worktrees(repo: only)
        for repo in try store.repos() where only == nil || repo.id == only {
            let workspaces = all.filter { isMain($0, repo) }
            // A remote project's branch is read over ssh: not on every sync (an unreachable host would stall each one for
            // its connect timeout). Its workspaces keep the branch they have; git.status and the like read it when asked.
            if remotes.of(repo.path) != nil, !workspaces.isEmpty { continue }
            let branch =
                remotes.of(repo.path) != nil
                ? repo.baseBranch : (try? Git.currentBranch(repo.path, remotes: remotes)) ?? repo.baseBranch
            if workspaces.isEmpty {
                try store.save(
                    Worktree(repoId: repo.id, branch: branch, path: repo.path, note: "Workspace 1", base: branch))
            }
            for worktree in workspaces where worktree.branch != branch || worktree.note.isEmpty {
                try store.update(Worktree.self, worktree.id) {
                    $0.branch = branch
                    if $0.note.isEmpty { $0.note = "Workspace 1" }   // was the project's "main" workspace
                }
            }
        }
    }

    /// One local project's .git, watched for its HEAD.
    struct HeadWatch: Sendable { let dir: String, watcher: FileWatcher }

    /// At start: workspaces catch up with branches switched while no daemon ran, and from then on follow them.
    func followHeads() {
        watchHeads()
        do { try syncMainWorkspaces() } catch {
            Log.store.error("workspaces didn't follow their folders' branches: \(error)")
        }
    }

    /// Workspaces follow their folder's branch as it moves, also when it's switched outside Kelp: a watcher on each local
    /// project's .git sees HEAD change, and the sync pushes the workspaces it updated (event.worktree), so listing only reads.
    /// Runs at start and whenever a project is written or removed (the store's change hook), always on `headQueue`: two
    /// runs side by side could each drop the other's new watcher, and a store write doesn't wait on FSEvents setup.
    /// Limit: a project that is itself a linked worktree (its .git a file) follows at the next start or new workspace.
    func watchHeads() {
        dispatchPrecondition(condition: .onQueue(headQueue))
        let local = (store.look("the projects") { try $0.repos() } ?? []).filter { remotes.of($0.path) == nil }
        let want = Dictionary(local.map { ($0.id, $0.path + "/.git") }, uniquingKeysWith: { a, _ in a })
        guard let have = heads.withLock({ $0?.mapValues(\.dir) }) else { return }
        var made: [String: HeadWatch] = [:]
        for (id, dir) in want where have[id] != dir {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            let fw = FileWatcher(root: dir, deliver: headQueue) { [weak self] paths in
                let real = paths.filter { !$0.contains("/logs/") }
                if Self.movesHead(real) {
                    do { try self?.syncMainWorkspaces(only: id) } catch {
                        Log.store.error("workspaces didn't follow their branch: \(error)")
                    }
                }
                // A branch moved (a merge into the base, a pull): a group whose work is in the base now is done with.
                if real.contains(where: { $0.contains("/refs/heads/") || $0.hasSuffix("/packed-refs") }) {
                    self?.tidyBranches(in: id)
                }
            }
            if let fw { made[id] = HeadWatch(dir: dir, watcher: fw) }
        }
        let gone = heads.withLock { [made] current -> [HeadWatch] in
            guard let all = current else { return Array(made.values) }   // stopped meanwhile
            let gone = all.filter { want[$0.key] != $0.value.dir }.map(\.value)
            current = all.filter { want[$0.key] == $0.value.dir }.merging(made) { old, _ in old }
            return gone
        }
        _ = gone   // their streams stop as they go, out of the lock
    }

    /// Whether events in a project's .git moved its own HEAD, which its workspaces follow: not FETCH_HEAD, ORIG_HEAD, a
    /// remote's HEAD, nor a linked worktree's (only the project's own folder's workspaces follow theirs).
    static func movesHead(_ paths: [String]) -> Bool { paths.contains { $0.hasSuffix("/.git/HEAD") } }

    /// The daemon stops: the folders aren't followed any more.
    func stopWatching() {
        let stopped = heads.withLock { current in
            defer { current = nil }
            return current
        }
        _ = stopped   // the streams stop here, out of the lock
    }

    /// A new workspace in the project's folder: instant, named "Workspace N" until its first prompt names it (see autoTitle).
    func createWorkspace(in repo: Repo) throws -> Worktree {
        // Read before the lock: a remote project's is read over ssh, and a host that doesn't answer would hold every
        // project's sync for its timeout.
        let branch = (try? Git.currentBranch(repo.path, remotes: remotes)) ?? repo.baseBranch
        let worktree = try workspaceLock.withLock {   // its "Workspace N" counts the workspaces there now
            try syncWorkspaces()   // names the project's first workspace, so the new one doesn't take "Workspace 1"
            let taken = Set(try store.worktrees(repo: repo.id).map(\.note))
            var number = 1
            while taken.contains("Workspace \(number)") { number += 1 }
            let worktree = Worktree(
                repoId: repo.id, branch: branch, path: repo.path, note: "Workspace \(number)", base: branch)
            try store.save(worktree)
            return worktree
        }
        notify(ChangedEvent.worktree)   // the coarse `event.changed`; its record went out as it was written
        return worktree
    }

    /// "Workspace 3" on branch "ws-3": instant, and renamed from the first prompt later (see autoTitle).
    func nextWorkspace(in repo: Repo) throws -> (name: String, branch: String) {
        let taken = Set(try store.worktrees(repo: repo.id).map(\.note))
        var number = 2
        while taken.contains("Workspace \(number)") || Git.branchExists(repo.path, "ws-\(number)", remotes: remotes) {
            number += 1
        }
        return ("Workspace \(number)", "ws-\(number)")
    }

    /// A workspace on a branch of its own, in a worktree of `repo`, as `asked` says: its `branch` (else "ws-N", or named
    /// after `note`), made from `base` (else the project's), checked out as it is (`existing`), or a pull request's head
    /// (`pr`). What its .kelp.yaml links, clones and starts waits for the user's trust in the file.
    func createBranchWorkspace(in repo: Repo, _ asked: WorktreeCreate) throws -> WorktreeCreate.Result {
        let note = asked.note, pr = asked.pr, existing = asked.existing == true
        // Its git would run on this Mac, not the host: a remote project's workspaces all share its folder.
        guard remotes.of(repo.path) == nil else {
            throw RPCError.invalidParams(
                "Remote projects work in their folder: branches in worktrees aren't available there yet.")
        }
        // Opened without Git: said in words, not as git's refusal.
        do { _ = try Git.root(of: repo.path, remotes: remotes) } catch {
            throw RPCError.invalidParams("“\(repo.name)” isn't a Git repository, so it has no branches.")
        }
        let auto = try nextWorkspace(in: repo)
        var branch = try clientRef(asked.branch.flatMap { $0.isEmpty ? nil : $0 }) ?? auto.branch
        // A name given for a new branch names it too, as a first prompt would (`nameBranch`), "-2" if it's taken.
        if asked.branch == nil, pr == nil, let given = note?.trimmingCharacters(in: .whitespaces), !given.isEmpty,
            !Naming.slug(given).isEmpty
        {
            let wanted = sessions.branchPrefix + Naming.slug(given)
            var suffix = 2
            branch = wanted
            while Git.branchExists(repo.path, branch, remotes: remotes) {
                branch = "\(wanted)-\(suffix)"
                suffix += 1
            }
        }
        if let pr {
            branch = try Git.fetchPullRequest(
                repo: repo.path, number: pr, wanted: asked.branch == nil ? nil : branch, remotes: remotes)
        }
        let base = try clientRef(asked.base.flatMap { $0.isEmpty ? nil : $0 }) ?? repo.baseBranch
        let into = Self.worktreesDir(root, repo, chosen: sessions.settings[SettingKeys.worktreesFolder])
        // A pull request's code, fetched now or under what it starts from (`holdsPullRequest`): it gets none of the project's
        // own files (.env), and nothing of .kelp.yaml runs on it until the user says so (below).
        let checksOut = existing || pr != nil
        let fromPR = pr != nil || Git.holdsPullRequest(repo.path, at: checksOut ? branch : base, remotes: remotes)
        let path = try Git.addWorktree(
            repo: repo.path, branch: branch, base: base, into: into, copyFiles: repo.copyFiles,
            existing: checksOut, copying: !fromPR, remotes: remotes)
        // "origin/x" checked out as the local "x" that follows it
        if existing, !Git.branchExists(repo.path, branch, remotes: remotes) {
            branch = branch.split(separator: "/", maxSplits: 1).last.map(String.init) ?? branch
        }
        var workspace = Worktree(
            repoId: repo.id, branch: branch, path: path, note: note ?? (asked.branch == nil ? auto.name : ""),
            base: base)
        workspace.madeBy = Sessions.asker
        try store.save(workspace)
        var result = WorktreeCreate.Result(worktree: workspace)
        // Everything .kelp.yaml does waits for the user's trust in this version of the file, not only `setup`: `tabs`
        // starts agents and `shared` links folders, and a freshly cloned repository wrote that file, not the user.
        // Checked and used from one read. A pull request brings code the file's trust doesn't cover (an install script of
        // its author's): nothing runs on it until the user says so, nor on a branch made on top of one (`fromPR`).
        let read = configAndTrust(repo.path), cfg = read.config, trusted = read.trusted && !fromPR
        if trusted {
            Git.linkShared(cfg.shared, repo: repo.path, worktree: path)
            for why in Git.cloneShared(cfg.clone, repo: repo.path, worktree: path) {
                Log.session.error(
                    ".kelp.yaml clone left out \(why, privacy: .public): the worktree is on another volume, or the path is busy"
                )
            }
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

    /// The workspace and its agents go. One in the project's folder leaves the folder as it is (a project keeps at least
    /// one); a worktree's folder goes too, and its branch with it unless it has commits no other branch has (`dropCommits`)
    /// or its folder holds changes (`force`).
    func removeWorkspace(_ workspace: Worktree, _ repo: Repo, force: Bool, dropCommits drop: Bool) throws {
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
        let branch = branchNow(of: workspace, in: repo)
        // A remote project's folder is on its host: looked for there.
        let host = remotes.of(repo.path)   // the project's: its worktrees are on its host too
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
                remotes: remotes)
            try sessions.pauseSessions(of: workspace.id)
            try Git.removeWorktree(
                repo: repo.path, path: workspace.path, branch: branch, force: force, dropCommits: drop,
                remotes: remotes)
        } else {
            try sessions.pauseSessions(of: workspace.id)
            // Gone already (a removal that stopped after the Trash): git's record and the branch mustn't stay behind.
            try Git.forgetWorktree(
                repo: repo.path, path: workspace.path, branch: branch, dropCommits: drop, remotes: remotes)
        }
        // Its sessions' turn refs live in the project's repository: dropped there, once the folder is gone. Not before:
        // a removal that fails keeps the workspace, and its turns keep their snapshots.
        for session in try store.sessions() where session.worktreeId == workspace.id {
            sessions.turns.dropRefs(of: session.id, in: repo.path)
        }
        sessions.discard(try store.sessions().filter { $0.worktreeId == workspace.id })
        try store.delete(workspace)
        notify(ChangedEvent.worktree)
    }

    /// A branch group done with, closed with nobody asked: one an agent made (`kelp worktree create`) once nobody is left
    /// on it, and anyone's once the work done on it since the group was made landed in the base branch (merged or
    /// fast-forwarded there, or its pull request merged with the branch where the forge last saw it). Never while an agent there works or asks, never with
    /// uncommitted files, never with commits that are only there, unless the merged pull request carries them. A landed
    /// group that still has chats is archived with them (nothing of theirs is lost), one without is removed: folder to the
    /// Trash, branch deleted. Limit: a remote project's groups aren't looked at; a branch merged while its agent worked
    /// goes at the next change of the project's branches, its pull request's next read or Kelp's next start.
    /// `someoneLeft`: a session there just ended; else an agent's empty branch goes only once it's 5 minutes old (its
    /// agent starts a moment after its branch).
    func tidyBranch(_ id: String, merged pr: GitHub.PullRequest? = nil, someoneLeft: Bool = false) {
        dispatchPrecondition(condition: .onQueue(headQueue))
        Log.store.attempt("tidying a branch group") {
            guard let workspace = try store.worktree(id), !workspace.archived,
                let repo = try store.repo(workspace.repoId),
                !isMain(workspace, repo), remotes.of(repo.path) == nil,
                FileManager.default.fileExists(atPath: workspace.path)
            else { return }
            let here = try store.sessions().filter { $0.worktreeId == id }.map {
                sessions.existing($0.id)?.snapshot ?? $0
            }
            .filter { $0.status != .exited }
            guard !here.contains(where: { [.working, .waiting].contains($0.status) }),
                try !Git.isDirty(workspace.path, remotes: remotes)
            else { return }
            let branch = branchNow(of: workspace, in: repo)
            let tip = try Git.line(["rev-parse", "HEAD"], cwd: workspace.path, remotes: remotes)
            // Only a branch that did something since the group was made: one opened to look at, already merged, stays.
            let moved = try Git.moved(repo: repo.path, branch, since: workspace.createdAt, remotes: remotes)
            let squashed =
                moved && pr.map { $0.headRefName == branch && $0.headRefOid != nil && $0.headRefOid == tip } ?? false
            let landed =
                squashed || (moved && Git.isIn(repo: repo.path, branch, base: repo.baseBranch, remotes: remotes))
            if landed, !here.isEmpty {
                try archive(workspace, repo)
            } else if landed
                || (workspace.madeBy != nil && here.isEmpty
                    && (someoneLeft || workspace.createdAt.timeIntervalSinceNow < -300))
            {
                do { try removeWorkspace(workspace, repo, force: false, dropCommits: squashed) } catch GitError.refused
                {
                    return   // work that's only there: kept, and its row says what
                }
            } else {
                return
            }
            if landed {
                notify(
                    LandedEvent(
                        worktree: id, name: workspace.displayName, base: repo.baseBranch, archived: !here.isEmpty))
            }
        }
    }

    /// Every branch group of `repo` (all at start): those done with while no daemon ran, or since its branches moved.
    func tidyBranches(in repo: String? = nil) {
        dispatchPrecondition(condition: .onQueue(headQueue))
        for workspace in store.look("the workspaces", { try $0.worktrees(repo: repo) }) ?? [] {
            tidyBranch(workspace.id)
        }
    }

    /// The project's other worktrees at `paths` (ones Kelp didn't make), each to the Trash, unless it's in use, holds
    /// work or isn't one of them: what was kept says why. A removed one's branch goes too if another branch has its
    /// commits.
    func removeWorktrees(_ paths: [String], of repo: Repo) throws -> RepoRemoveWorktrees.Result {
        let linked = try Git.linkedWorktrees(repo.path, remotes: remotes)
        let ours = try RepoWorktreeSizes.ours(store, repo)
        var out = RepoRemoveWorktrees.Result(removed: [], kept: [:])
        // A paused agent comes back where it last worked: its folder is as much in use as a running one's.
        let stored = try store.sessions().filter { $0.status != .exited }.map(\.currentDir)
        let inUse = sessions.live.all.map(\.snapshot.currentDir) + stored
        for path in paths {
            guard let worktree = linked.first(where: { $0.path == path }), !ours.contains(RepoWorktreeSizes.real(path))
            else {
                out.kept[path] = "Not one of the project's other worktrees."
                continue
            }
            // Nothing in it yet is what a worktree an agent just made looks like: its folder would go from under it.
            let real = RepoWorktreeSizes.real(path) + "/"
            if inUse.contains(where: { (RepoWorktreeSizes.real($0) + "/").hasPrefix(real) }) {
                out.kept[path] = "An agent works in it."
                continue
            }
            // git removes one whose commits are on no branch (a detached HEAD): they'd be left to `git gc`.
            if case let commits = Git.commitsOnNoBranch(path, remotes: remotes), commits > 0 {
                out.kept[path] = "It has \(commits) commit\(commits == 1 ? "" : "s") on no branch (a detached HEAD)."
                continue
            }
            do {
                // Kept with changes, untracked files or a lock; else the folder goes to the Trash, ignored files (.env, a
                // local database) and all, which `git worktree remove` would delete for good. Its branch stays: below.
                try Git.removeWorktree(repo: repo.path, path: path, branch: nil, force: false, remotes: remotes)
                // -d: only if its commits are on another branch
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
