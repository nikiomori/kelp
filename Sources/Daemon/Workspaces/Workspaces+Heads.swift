import Core
import Foundation
import GitKit
import os

/// Workspaces follow the branch each project's folder is on: its .git's HEAD, watched.
extension Workspaces {
    /// The .git folder of one local project, watched for changes to its HEAD.
    struct HeadWatch: Sendable { let dir: String, watcher: FileWatcher }

    /// At start: workspaces catch up with branches switched while no daemon ran, and from then on follow them.
    func followHeads() {
        watchHeads()
        do { try syncMainWorkspaces() } catch {
            Log.store.error("workspaces didn't follow their folders' branches: \(error)")
        }
    }

    /// Workspaces follow their folder's branch as it moves, including when it is switched outside Kelp: a watcher on
    /// each local project's .git sees HEAD change, and the sync pushes the workspaces it updated (event.worktree), so
    /// listing only reads.
    /// This runs at start and whenever a project is written or removed (the store's change hook), always on
    /// `headQueue`: two runs side by side could each drop the other's new watcher, and a store write shouldn't wait on
    /// FSEvents setup.
    /// Limit: a project that is itself a linked worktree (its .git is a file) follows only at the next start or the
    /// next new workspace.
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

    /// Whether file events in a project's .git moved the project's own HEAD, which its workspaces follow. FETCH_HEAD,
    /// ORIG_HEAD, a remote's HEAD and a linked worktree's HEAD don't count (only the workspaces of the project's own
    /// folder follow that HEAD).
    static func movesHead(_ paths: [String]) -> Bool { paths.contains { $0.hasSuffix("/.git/HEAD") } }

    /// The daemon stops: the folders aren't followed any more.
    func stopWatching() {
        let stopped = heads.withLock { current in
            defer { current = nil }
            return current
        }
        _ = stopped   // the streams stop here, out of the lock
    }
}
