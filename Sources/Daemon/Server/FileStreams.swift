import Core
import Foundation
import os

/// Shares one FSEvents stream per folder among every watch in it (`Watches`). Before, a workspace's git, files,
/// databases and artifacts, and the folders of its open files, each had a recursive stream of its own. A watch takes
/// the stream of a folder it's in if one runs (not through a build folder, whose events a stream drops), or else starts
/// one for its own folder. The stream stops with the last watch that held it. Each watch hears only the events in its
/// folder, on a queue of its own, because what it makes of them may run git (check-ignore) and one slow folder must not
/// hold up the others.
final class FileStreams: Sendable {
    /// One watch's hold on a stream. The stream is let go when the hold is freed.
    final class Hold: Sendable {
        fileprivate let streams: FileStreams, root: String, id: Int
        fileprivate init(_ streams: FileStreams, root: String, id: Int) {
            self.streams = streams
            self.root = root
            self.id = id
        }
        deinit { streams.release(root, id) }
    }
    private struct Listener: Sendable {
        let prefixes: [String], queue: DispatchQueue, heard: @Sendable ([FileWatcher.Change]) -> Void
    }
    private struct Stream {
        var watcher: FileWatcher?
        var listeners: [Int: Listener] = [:]
    }
    private let state = OSAllocatedUnfairLock<(next: Int, byRoot: [String: Stream])>(initialState: (0, [:]))

    /// Streams running now (tests).
    var count: Int { state.withLock { $0.byRoot.count } }

    /// `heard` is told the events in `folder` (as FSEvents names them: /tmp is /private/tmp) until the hold goes.
    func hold(_ folder: String, _ heard: @escaping @Sendable ([FileWatcher.Change]) -> Void) -> Hold {
        let folder = folder.count > 1 && folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        let listener = Listener(
            prefixes: Array(Set([folder, Paths.real(folder) ?? folder].map { $0 + "/" })),
            queue: DispatchQueue(label: "kelp.watches.files"), heard: heard)
        // This runs outside the lock because `covers` resolves links. A stream that went away meanwhile is started
        // again for that root.
        let root = state.withLock { Array($0.byRoot.keys) }.first { Self.covers($0, folder) } ?? folder
        let (id, start) = state.withLock { state -> (Int, Bool) in
            state.next += 1
            let start = state.byRoot[root] == nil
            state.byRoot[root, default: Stream()].listeners[state.next] = listener
            return (state.next, start)
        }
        if start {
            let watcher = FileWatcher(changesIn: root, deliver: DispatchQueue(label: "kelp.watches.stream")) {
                [weak self] changes in self?.tell(root, changes)
            }
            let unused = state.withLock { state -> FileWatcher? in
                // If the stream was let go meanwhile (or got a watcher already), this watcher stops.
                guard state.byRoot[root] != nil, state.byRoot[root]?.watcher == nil else { return watcher }
                state.byRoot[root]?.watcher = watcher
                return nil
            }
            _ = unused   // an unused watcher stops here, outside the lock
        }
        return Hold(self, root: root, id: id)
    }

    /// Whether `root`'s stream hears what happens in `folder`.
    static func covers(_ root: String, _ folder: String) -> Bool {
        Paths.inside(folder, root)
            && !FileWatcher.isBuildOutput(Paths.realNearest(folder) + "/", under: [Paths.realNearest(root) + "/"])
    }

    /// Gives each listener of `root`'s stream the events in its folder, and the events on a folder above it that say
    /// anything may have changed (a folder to scan again).
    private func tell(_ root: String, _ changes: [FileWatcher.Change]) {
        let listeners = state.withLock { $0.byRoot[root].map { Array($0.listeners.values) } ?? [] }
        for listener in listeners {
            let mine = changes.filter { change in
                let path = change.path.hasSuffix("/") ? change.path : change.path + "/"
                return listener.prefixes.contains {
                    path.hasPrefix($0) || $0.hasPrefix(path) && change.flags & FileWatcher.Change.itemFlags == 0
                }
            }
            if !mine.isEmpty { listener.queue.async { listener.heard(mine) } }
        }
    }

    private func release(_ root: String, _ id: Int) {
        let gone = state.withLock { state -> FileWatcher? in
            state.byRoot[root]?.listeners[id] = nil
            guard state.byRoot[root]?.listeners.isEmpty == true else { return nil }
            return state.byRoot.removeValue(forKey: root)?.watcher
        }
        _ = gone   // the stream stops here, outside the lock
    }
}
