import Foundation
import os
import Core
import GitKit

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
    /// What discards threw away, for a minute (`git.undoDiscard`): a file each, named by its folder and the name the
    /// caller gave it, so the Undo still works after the daemon was upgraded in place, restarted or crashed.
    var discards: URL { root.appendingPathComponent("discarded") }
    private func discardFile(folder: String, name: String?) -> URL {
        discards.appendingPathComponent(Self.digest(folder + "\0" + (name ?? "")) + ".json")
    }
    /// Keeps `d` under `name` in `folder`, dropping what's past its minute.
    func keepDiscard(_ d: Discarded, folder: String, name: String?) {
        sweepDiscards()
        Log.store.attempt("keeping a discard for its Undo") {
            try FileManager.default.createDirectory(at: discards, withIntermediateDirectories: true)
            try JSONEncoder().encode(d).write(to: discardFile(folder: folder, name: name), options: .atomic)
        }
        // Gone after its minute even when nothing else is discarded: a patch can be large.
        DispatchQueue.global().asyncAfter(deadline: .now() + 61) { [weak self] in self?.sweepDiscards() }
    }
    /// The discard kept under `name`, taken (an Undo is once: moved aside first, so two Undos can't both have it), if its
    /// minute isn't over.
    func takeDiscard(folder: String, name: String?) -> Discarded? {
        let file = discardFile(folder: folder, name: name), taken = file.appendingPathExtension(UUID().uuidString)
        guard rename(file.path, taken.path) == 0 else { return nil }
        defer { unlink(taken.path) }
        let d = Log.store.attempt("reading a discard") { try JSONDecoder().decode(Discarded.self, from: Data(contentsOf: taken)) }
        return d.flatMap { $0.at.timeIntervalSinceNow > -60 ? $0 : nil }
    }
    /// Drops what's past its minute; at start too, for what an earlier daemon kept.
    func sweepDiscards() {
        let old = Date().timeIntervalSince1970 - 60
        for name in FileManager.default.enumerator(atPath: discards.path)?.allObjects as? [String] ?? [] {
            let path = discards.appendingPathComponent(name).path
            var st = stat()
            if stat(path, &st) == 0, Double(st.st_mtimespec.tv_sec) < old { unlink(path) }
        }
    }
    struct Discarded: Codable, Sendable {
        var at = Date()
        var patch: Data, hunk: Bool
    }

    init(root: URL, store: Store, remotes: Remotes, sessions: Sessions, clients: Clients) {
        self.root = root
        self.store = store
        self.remotes = remotes
        self.sessions = sessions
        self.clients = clients
        self.routines = Routines(store: store, sessions: sessions, clients: clients)
        sweepDiscards()
    }

    func notify(_ e: some RPCEvent, to only: Set<Int>? = nil) { clients.notify(e, to: only) }

    /// Makes the folder, or fails if anything is there already: of two clones racing for one name, exactly one gets it.
    static func claim(_ dest: String) -> Bool { mkdir(dest, 0o755) == 0 }

    /// The folder of the workspace a client named.
    func folder(_ worktreeId: String) throws -> String { try store.worktree(named: worktreeId).path }

    /// Where a project's worktrees go: its name made safe for a folder ("../x" can't leave `worktrees/`) and its id, so two
    /// projects with one name don't share a folder.
    /// `chosen`: the folder set in Settings › Git (`worktrees.folder`, `~` for home): the project's go in a subfolder named
    /// after it there, where an editor or Finder finds them.
    static func worktreesDir(_ root: URL, _ r: Repo, chosen: String? = nil) -> URL {
        let name = Git.slug(r.name).replacingOccurrences(of: ".", with: "-")
        if let chosen = chosen?.trimmingCharacters(in: .whitespaces), !chosen.isEmpty {
            return URL(fileURLWithPath: (chosen as NSString).expandingTildeInPath).appendingPathComponent(name)
        }
        return root.appendingPathComponent("worktrees").appendingPathComponent(name + "-" + r.id.prefix(8))
    }

    static let placeholderName = #"^Workspace \d+$"#

    func isMain(_ w: Worktree, _ r: Repo) -> Bool { w.path == r.path }

    /// A branch group's branch as it is: renamed in its folder (`git branch -m`), what the record says no longer exists, and
    /// closing it would ask about nothing and then fail. A switch to another branch doesn't count: that one isn't the group's to delete.
    func branchNow(of w: Worktree, in r: Repo) -> String {
        guard !Git.branchExists(r.path, w.branch, remotes: remotes),
              let now = Log.store.attempt("reading \(w.path)'s branch", { try Git.currentBranch(w.path, remotes: remotes) }), now != "HEAD" else {
            return w.branch
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
        for r in try store.repos() {
            let workspaces = all.filter { isMain($0, r) }
            // A remote project's branch is read over ssh: not on every sync (an unreachable host would stall each one for
            // its connect timeout). Its workspaces keep the branch they have; git.status and the like read it when asked.
            if remotes.of(r.path) != nil, !workspaces.isEmpty { continue }
            let branch = remotes.of(r.path) != nil ? r.baseBranch : (try? Git.currentBranch(r.path, remotes: remotes)) ?? r.baseBranch
            if workspaces.isEmpty { try store.save(Worktree(repoId: r.id, branch: branch, path: r.path, note: "Workspace 1", base: branch)) }
            for w in workspaces where w.branch != branch || w.note.isEmpty {
                try store.update(Worktree.self, w.id) {
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
        do { try syncMainWorkspaces() } catch { Log.store.error("workspaces didn't follow their folders' branches: \(error)") }
    }

    /// Workspaces follow their folder's branch as it moves, also when it's switched outside Kelp: a watcher on each local
    /// project's .git sees HEAD change, and the sync pushes the workspaces it updated (event.worktree), so listing only reads.
    /// Runs at start and whenever a project is written or removed (the store's change hook), always on `headQueue`: two
    /// runs side by side could each drop the other's new watcher, and a store write doesn't wait on FSEvents setup.
    /// Limit: a project that is itself a linked worktree (its .git a file) follows at the next start or new workspace.
    func watchHeads() {
        dispatchPrecondition(condition: .onQueue(headQueue))
        let local = ((try? store.repos()) ?? []).filter { remotes.of($0.path) == nil }
        let want = Dictionary(local.map { ($0.id, $0.path + "/.git") }, uniquingKeysWith: { a, _ in a })
        guard let have = heads.withLock({ $0?.mapValues(\.dir) }) else { return }
        var made: [String: HeadWatch] = [:]
        for (id, dir) in want where have[id] != dir {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            let fw = FileWatcher(root: dir, deliver: headQueue) { [weak self] paths in
                guard paths.contains(where: { $0.hasSuffix("/HEAD") && !$0.contains("/logs/") }) else { return }
                do { try self?.syncMainWorkspaces() } catch { Log.store.error("workspaces didn't follow their branch: \(error)") }
            }
            if let fw { made[id] = HeadWatch(dir: dir, watcher: fw) }
        }
        let gone = heads.withLock { [made] h -> [HeadWatch] in
            guard let all = h else { return Array(made.values) }   // stopped meanwhile
            let gone = all.filter { want[$0.key] != $0.value.dir }.map(\.value)
            h = all.filter { want[$0.key] == $0.value.dir }.merging(made) { old, _ in old }
            return gone
        }
        _ = gone   // their streams stop as they go, out of the lock
    }

    /// The daemon stops: the folders aren't followed any more.
    func stopWatching() {
        let h = heads.withLock { h in defer { h = nil }; return h }
        _ = h   // the streams stop here, out of the lock
    }

    /// A new workspace in the project's folder: instant, named "Workspace N" until its first prompt names it (see autoTitle).
    func createWorkspace(in r: Repo) throws -> Worktree {
        // Read before the lock: a remote project's is read over ssh, and a host that doesn't answer would hold every
        // project's sync for its timeout.
        let branch = (try? Git.currentBranch(r.path, remotes: remotes)) ?? r.baseBranch
        let w = try workspaceLock.withLock {   // its "Workspace N" counts the workspaces there now
            try syncWorkspaces()   // names the project's first workspace, so the new one doesn't take "Workspace 1"
            let taken = Set(try store.worktrees(repo: r.id).map(\.note))
            var n = 1
            while taken.contains("Workspace \(n)") { n += 1 }
            let w = Worktree(repoId: r.id, branch: branch, path: r.path, note: "Workspace \(n)", base: branch)
            try store.save(w)
            return w
        }
        notify(ChangedEvent.worktree)   // the coarse `event.changed`; its record went out as it was written
        return w
    }

    /// "Workspace 3" on branch "ws-3": instant, and renamed from the first prompt later (see autoTitle).
    func nextWorkspace(in r: Repo) throws -> (name: String, branch: String) {
        let taken = Set(try store.worktrees(repo: r.id).map(\.note))
        var n = 2
        while taken.contains("Workspace \(n)") || Git.branchExists(r.path, "ws-\(n)", remotes: remotes) { n += 1 }
        return ("Workspace \(n)", "ws-\(n)")
    }
}
