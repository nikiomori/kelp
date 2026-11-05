import Foundation
import os
import Core
import GitKit

/// What clients watch (`watch.start`). A topic and key is read only while someone watches it, once for all of them, and
/// pushed to them when it changed: the first value right away, the last one to whoever joins. A git topic is read when its
/// folder's files change (FSEvents here, not one watcher per panel in the app); the rest on their topic's clock, which
/// each read sets (CI goes on only while a run does). A connection that goes away stops watching.
final class Watches: Sendable {
    struct Key: Hashable, Sendable { let topic: WatchTopic, key: String }
    private struct Entry {
        let number: Int                // this watch's: a read begun for one stopped since says nothing to the next
        var watchers: Set<Int>
        var last: Data?                // the event as last sent (sorted keys): the next goes out only when it differs
        var reading = false, again = false
        var timer: Int?                // the scheduled read's number; a newer one (or none) makes it a no-op
        var files: FileWatcher?
        var fastUntil = Date.distantPast
        var tag: String?               // context: the session's status at the last read
        var quiet = 0                  // reads in a row that found nothing new
    }
    private let entries = OSAllocatedUnfairLock<[Key: Entry]>(initialState: [:])
    private let closed = OSAllocatedUnfairLock(initialState: false)
    /// Watches running now (tests).
    var count: Int { entries.withLock { $0.count } }
    private let numbers = OSAllocatedUnfairLock(initialState: 0)   // watches' and scheduled reads'
    /// Reads so far by key: tests see one read for two watchers, and none after the last one left.
    let reads = OSAllocatedUnfairLock<[Key: Int]>(initialState: [:])
    var running: Int { entries.withLock { $0.count } }
    /// How a topic is read now: the event as sent (nil: nothing to say) and when to read it again with nothing else
    /// saying so (nil: only when something does). The daemon's (it answers the topic's methods as a client would), set
    /// once it's made; a test's stand-in in its place (to hold one read back while a newer one finishes). In a struct, not
    /// bare in the lock: see `Store.Listener`.
    struct Reading: Sendable { var read: (@Sendable (Key, _ fast: Bool) async -> (Data?, TimeInterval?))? }
    let reading = OSAllocatedUnfairLock(initialState: Reading())
    private let store: Store
    private let clients: Clients

    private let remotes: Remotes

    init(store: Store, clients: Clients, remotes: Remotes) {
        self.store = store
        self.clients = clients
        self.remotes = remotes
    }

    func start(_ k: Key, conn: Int) {
        guard !closed.withLock({ $0 }) else { return }   // the daemon stopped them all: a late watch.start starts none
        let n = numbers.withLock { $0 += 1; return $0 }
        let (new, again, last) = entries.withLock { e -> (Bool, Bool, Data?) in
            guard var x = e[k] else { e[k] = Entry(number: n, watchers: [conn]); return (true, false, nil) }
            let again = !x.watchers.insert(conn).inserted
            if again { x.fastUntil = Date().addingTimeInterval(45); x.quiet = 0 }
            e[k] = x
            return (false, again, x.last)
        }
        // Stopped while this was taking its place: it goes too, rather than run on unseen.
        if closed.withLock({ $0 }) {
            let late = entries.withLock { e in defer { e = [:] }; return e }
            _ = late
            return
        }
        if new { begin(k) } else if again { read(k) } else if let last { clients.targets([conn]).forEach { $0.send(last) } }
    }

    func stop(_ k: Key, conn: Int) {
        let gone = entries.withLock { e -> Entry? in
            guard var x = e[k] else { return nil }
            x.watchers.remove(conn)
            if x.watchers.isEmpty { e[k] = nil; return x }
            e[k] = x; return nil
        }
        _ = gone   // its scheduled read finds it gone; its FileWatcher stops as it goes
    }

    /// A connection went away.
    func drop(_ conn: Int) {
        let gone = entries.withLock { e -> [Entry] in
            var out: [Entry] = []
            for (k, var x) in e where x.watchers.contains(conn) {
                x.watchers.remove(conn)
                if x.watchers.isEmpty { e[k] = nil; out.append(x) } else { e[k] = x }
            }
            return out
        }
        _ = gone   // released here, out of the lock: their FileWatchers stop as they go
    }

    func stopAll() {
        closed.withLock { $0 = true }
        let all = entries.withLock { e in defer { e = [:] }; return e }
        _ = all   // released off the lock (a file watch's deinit waits on its own queue)
    }

    /// Something says it may have changed (a session's status, for its context): read again if it did.
    func touched(_ k: Key, tag: String) {
        let go = entries.withLock { e -> Bool in
            guard var x = e[k], x.tag != tag else { return false }
            x.tag = tag
            e[k] = x
            return true
        }
        if go { read(k) }
    }

    private func begin(_ k: Key) {
        if let (root, matters) = folder(k) {
            // Debounced: a save is several events, a checkout hundreds. A queue of its own: `matters` may run git
            // (check-ignore), and one slow folder must not hold up every other watch.
            let fw = FileWatcher(root: root, deliver: DispatchQueue(label: "kelp.watches.files")) { [weak self] paths in
                guard let self, matters(paths) else { return }
                soon(k)
            }
            entries.withLock { e in e[k]?.files = fw }
        }
        read(k)
    }

    /// The folder whose file events can change a topic, and which of them do; nil: none (a remote project's folder here
    /// holds only its marker, and the rest go by their clock).
    private func folder(_ k: Key) -> (String, @Sendable ([String]) -> Bool)? {
        switch k.topic {
        case .git, .files, .artifacts:
            guard let w = try? store.worktree(k.key), remotes.of(w.path) == nil else { return nil }
            if k.topic == .artifacts { return (w.path, { $0.contains { $0.contains("/\(Artifacts.folder)/") } }) }
            let touches = k.topic == .git ? Git.touchesStatus : Git.touchesFileList, ignored = IgnoredFolders(root: w.path, remotes: remotes)
            return (w.path, { touches(ignored.drop($0)) })
        case .file:
            guard k.key.hasPrefix("/"), remotes.containing(k.key) == nil else { return nil }
            // Its folder, as FSEvents names it (/tmp is /private/tmp): the file itself may not be there to resolve.
            // Limit: a symlink's target changing elsewhere isn't seen; watch the target's folder if that matters.
            let dir = (k.key as NSString).deletingLastPathComponent, name = (k.key as NSString).lastPathComponent
            let names = Set([k.key, ((Paths.real(dir) ?? dir) as NSString).appendingPathComponent(name)])
            return (dir, { $0.contains(where: names.contains) })
        default: return nil
        }
    }

    private func soon(_ k: Key) {
        let pending = entries.withLock { $0[k]?.timer != nil }
        if !pending { schedule(k, after: 0.4) }
    }

    private func schedule(_ k: Key, after t: TimeInterval) {
        let n = numbers.withLock { $0 += 1; return $0 }
        let ok = entries.withLock { e -> Bool in
            guard var x = e[k] else { return false }
            x.timer = n
            e[k] = x
            return true
        }
        guard ok else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + t) { [weak self] in
            guard let self, entries.withLock({ $0[k]?.timer == n }) else { return }   // stopped, or read since
            read(k)
        }
    }

    private func read(_ k: Key) {
        let go = entries.withLock { e -> (Date, Int)? in
            guard var x = e[k] else { return nil }
            if x.reading {
                x.again = true
                e[k] = x
                return nil
            }
            x.reading = true
            x.timer = nil
            e[k] = x
            return (x.fastUntil, x.number)
        }
        guard let (fastUntil, number) = go else { return }
        Task {
            let began = Date()
            let (line, next) = await reading.withLock({ $0.read })?(k, fastUntil > Date()) ?? (nil, nil)
            reads.withLock { $0[k, default: 0] += 1 }
            let ours = entries.withLock { e -> (send: Data?, to: Set<Int>, again: Bool, quiet: Int)? in
                // Stopped meanwhile, maybe started again: what it read may be older than the new watch's first value,
                // and the new one keeps its own clock.
                guard var x = e[k], x.number == number else { return nil }
                x.reading = false
                let changed = line != nil && line != x.last
                if changed { x.last = line }
                x.quiet = changed ? 0 : x.quiet + 1
                let again = x.again; x.again = false
                e[k] = x
                return (changed ? line : nil, x.watchers, again, x.quiet)
            }
            guard let (send, to, again, quiet) = ours else { return }
            if let send { clients.targets(to).forEach { $0.send(send) } }
            // Files changing all through a read: not back to back, or a large repository's git never stops; and not more than
            // 8 s behind either, or a slow repository's panels stay stale while an agent writes.
            if again { schedule(k, after: min(8, max(0.4, 4 * Date().timeIntervalSince(began)))) }
            else if let next { schedule(k, after: fastUntil > Date() ? next : Self.slowed(k.topic, next, quiet: quiet)) }
        }
    }

    /// When to read again what's asked over the network (gh, glab, ssh) after `quiet` reads that found nothing new: twice
    /// as long each time, so projects nobody is working on stop costing processes, quota and wake-ups. A change, or a
    /// watcher asking again, starts over. A CI run going on isn't slowed: its clock is short for a reason.
    static func slowed(_ topic: WatchTopic, _ next: TimeInterval, quiet: Int) -> TimeInterval {
        let polls = switch topic {
        case .pr, .git, .files, .ports: next >= 10
        case .ci: next >= 120
        default: false
        }
        guard polls else { return next }
        return min(next * pow(2, Double(min(quiet, 6))), next >= 60 ? next * 8 : 60)
    }
}
