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

    /// Every project keeps at least one workspace; workspaces follow the folder's checked-out branch.
    func syncMainWorkspaces() throws { try workspaceLock.withLock { try syncWorkspaces() } }

    /// The caller holds `workspaceLock`.
    private func syncWorkspaces() throws {
        let all = try store.worktrees(repo: nil)
        for repo in try store.repos() {
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
                guard paths.contains(where: { $0.hasSuffix("/HEAD") && !$0.contains("/logs/") }) else { return }
                do { try self?.syncMainWorkspaces() } catch {
                    Log.store.error("workspaces didn't follow their branch: \(error)")
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
}
