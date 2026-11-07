import Core
import Foundation

/// What the git handlers are handed (GitHandlers.swift: source control, files and review comments): the workspaces'
/// records, how to reach a remote project's host, what discards threw away, and the sessions a turn's diff reads and a
/// review is sent to.
struct SourceControl: Sendable {
    let root: URL
    let store: Store
    let remotes: Remotes
    let sessions: Sessions   // a turn's diff is where its agent works now; comments go into an agent

    /// The folder of the workspace a client named.
    func folder(_ worktreeId: String) throws -> String { try store.worktree(named: worktreeId).path }

    /// What discards threw away, for a minute (`git.undoDiscard`): a file each, named by its folder and the name the
    /// caller gave it, so the Undo still works after the daemon was upgraded in place, restarted or crashed.
    var discards: URL { Self.discards(root) }
    static func discards(_ root: URL) -> URL { root.appendingPathComponent("discarded") }
    private func discardFile(folder: String, name: String?) -> URL {
        discards.appendingPathComponent(Workspaces.digest(folder + "\0" + (name ?? "")) + ".json")
    }
    /// Keeps `discard` under `name` in `folder`, dropping what's past its minute.
    /// Kept for its Undo before the files change (`Git.discard`'s `keep`): one that can't be kept (a full disk) isn't made.
    func keepDiscard(_ discard: Discarded, folder: String, name: String?) throws {
        Self.sweepDiscards(root)
        do {
            try FileManager.default.createDirectory(at: discards, withIntermediateDirectories: true)
            try JSONEncoder().encode(discard).write(to: discardFile(folder: folder, name: name), options: .atomic)
        } catch {
            throw RPCError.internalError(
                "Nothing was discarded: its Undo couldn't be kept (\(error.localizedDescription)).")
        }
        // Gone after its minute even when nothing else is discarded: a patch can be large.
        let root = root
        DispatchQueue.global().asyncAfter(deadline: .now() + 61) { Self.sweepDiscards(root) }
    }
    /// The discard kept under `name`, if its minute isn't over, handed to `putBack`: taken (an Undo is once: moved aside
    /// first, so two Undos can't both have it), and kept again if `putBack` throws, for another try within its minute.
    /// False: there's none.
    func undoDiscard(folder: String, name: String?, _ putBack: (Discarded) throws -> Void) throws -> Bool {
        let file = discardFile(folder: folder, name: name), taken = file.appendingPathExtension(UUID().uuidString)
        guard rename(file.path, taken.path) == 0 else { return false }
        let discard = Log.store.attempt("reading a discard") {
            try JSONDecoder().decode(Discarded.self, from: Data(contentsOf: taken))
        }
        guard let discard, discard.at.timeIntervalSinceNow > -60 else {
            unlink(taken.path)
            return false
        }
        do { try putBack(discard) } catch {
            // A newer one has its name: that one stays.
            if renamex_np(taken.path, file.path, UInt32(RENAME_EXCL)) != 0 { unlink(taken.path) }
            throw error
        }
        unlink(taken.path)
        return true
    }
    /// Drops what's past its minute; at start too, for what an earlier daemon kept.
    static func sweepDiscards(_ root: URL) {
        let old = Date().timeIntervalSince1970 - 60, discards = discards(root)
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
}
