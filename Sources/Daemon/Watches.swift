import Core
import Foundation
import GitKit
import os

/// What clients watch (`watch.start`). A topic and key is read only while someone watches it, once for all of them, and
/// pushed to them when it changed: the first value right away, the last one to whoever joins. A git topic is read when its
/// folder's files change (FSEvents here, not one watcher per panel in the app); the rest on their topic's clock, which
/// each read sets (CI goes on only while a run does). A connection that goes away stops watching.
final class Watches: Sendable {
    struct Key: Hashable, Sendable { let topic: WatchTopic, key: String }
    private struct Entry {
        let number: Int   // this watch's: a read begun for one stopped since says nothing to the next
        var watchers: Set<Int>
        var last: Data?   // the event as last sent (sorted keys): the next goes out only when it differs
        var reading = false, again = false
        var timer: Int?   // the scheduled read's number; a newer one (or none) makes it a no-op
        var files: FileWatcher?
        var fastUntil = Date.distantPast
        var tag: String?   // context: the session's status at the last read
        var quiet = 0   // reads in a row that found nothing new
        var topic: Topic?   // what it is, asked once as it begins
    }
    private let entries = OSAllocatedUnfairLock<[Key: Entry]>(initialState: [:])
    private let closed = OSAllocatedUnfairLock(initialState: false)
    /// Watches running now (tests).
    var count: Int { entries.withLock { $0.count } }
    private let numbers = OSAllocatedUnfairLock(initialState: 0)   // watches' and scheduled reads'
    /// Reads so far by key, counted once a test sets it to `[:]`: one read for two watchers, and none after the last one
    /// left. Nil, as the daemon runs: a count for every key ever watched would only grow.
    let reads = OSAllocatedUnfairLock<[Key: Int]?>(initialState: nil)
    /// What a topic is: the folder whose file events can change it and which of them do, how it's read now (the event as
    /// sent, nil: nothing to say; and when to read it again with nothing else saying so, nil: only when something does),
    /// and from which clock on its reads back off while nothing changes (`slowed`).
    struct Topic: Sendable {
        var folder: (String, @Sendable ([String]) -> Bool)?
        var backsOffFrom = TimeInterval.infinity
        var read: @Sendable (_ fast: Bool) async -> (Data?, TimeInterval?)
    }
    /// Each key's topic: the daemon's (`Daemon.topic`, one switch for them all; it answers the topics' methods as a
    /// client would), set once it's made; a test's stand-in in its place (to hold one read back while a newer one
    /// finishes). In a struct, not bare in the lock: see `Store.Listener`.
    struct Reading: Sendable { var topic: (@Sendable (Key) -> Topic)? }
    let reading = OSAllocatedUnfairLock(initialState: Reading())
    private let store: Store
    private let clients: Clients

    private let remotes: Remotes

    init(store: Store, clients: Clients, remotes: Remotes) {
        self.store = store
        self.clients = clients
        self.remotes = remotes
    }

    func start(_ key: Key, conn: Int) {
        guard !closed.withLock({ $0 }) else { return }   // the daemon stopped them all: a late watch.start starts none
        let number = numbers.withLock {
            $0 += 1
            return $0
        }
        let (new, again, last) = entries.withLock { byKey -> (Bool, Bool, Data?) in
            guard var entry = byKey[key] else {
                byKey[key] = Entry(number: number, watchers: [conn])
                return (true, false, nil)
            }
            let again = !entry.watchers.insert(conn).inserted
            if again {
                entry.fastUntil = Date().addingTimeInterval(45)
                entry.quiet = 0
            }
            byKey[key] = entry
            return (false, again, entry.last)
        }
        // Stopped while this was taking its place: it goes too, rather than run on unseen.
        if closed.withLock({ $0 }) {
            let late = entries.withLock { byKey in
                defer { byKey = [:] }
                return byKey
            }
            _ = late
            return
        }
        if new {
            begin(key)
        } else if again {
            read(key)
        } else if let last {
            clients.targets([conn]).forEach { $0.send(last) }
        }
    }

    func stop(_ key: Key, conn: Int) {
        let gone = entries.withLock { byKey -> Entry? in
            guard var entry = byKey[key] else { return nil }
            entry.watchers.remove(conn)
            if entry.watchers.isEmpty {
                byKey[key] = nil
                return entry
            }
            byKey[key] = entry
            return nil
        }
        _ = gone   // its scheduled read finds it gone; its FileWatcher stops as it goes
    }

    /// A connection went away.
    func drop(_ conn: Int) {
        let gone = entries.withLock { byKey -> [Entry] in
            var out: [Entry] = []
            for (key, var entry) in byKey where entry.watchers.contains(conn) {
                entry.watchers.remove(conn)
                if entry.watchers.isEmpty {
                    byKey[key] = nil
                    out.append(entry)
                } else {
                    byKey[key] = entry
                }
            }
            return out
        }
        _ = gone   // released here, out of the lock: their FileWatchers stop as they go
    }

    func stopAll() {
        closed.withLock { $0 = true }
        let all = entries.withLock { byKey in
            defer { byKey = [:] }
            return byKey
        }
        _ = all   // released off the lock (a file watch's deinit waits on its own queue)
    }

    /// Something says it may have changed (a session's status, for its context): read again if it did.
    func touched(_ key: Key, tag: String) {
        let go = entries.withLock { byKey -> Bool in
            guard var entry = byKey[key], entry.tag != tag else { return false }
            entry.tag = tag
            byKey[key] = entry
            return true
        }
        if go { read(key) }
    }

    private func begin(_ key: Key) {
        let topic = reading.withLock { $0.topic }?(key)
        entries.withLock { byKey in byKey[key]?.topic = topic }
        if let (root, matters) = topic?.folder {
            // Debounced: a save is several events, a checkout hundreds. A queue of its own: `matters` may run git
            // (check-ignore), and one slow folder must not hold up every other watch.
            let fw = FileWatcher(root: root, deliver: DispatchQueue(label: "kelp.watches.files")) { [weak self] paths in
                guard let self, matters(paths) else { return }
                soon(key)
            }
            entries.withLock { byKey in byKey[key]?.files = fw }
        }
        read(key)
    }

    private func soon(_ key: Key) {
        let pending = entries.withLock { $0[key]?.timer != nil }
        if !pending { schedule(key, after: 0.4) }
    }

    private func schedule(_ key: Key, after delay: TimeInterval) {
        let number = numbers.withLock {
            $0 += 1
            return $0
        }
        let ok = entries.withLock { byKey -> Bool in
            guard var entry = byKey[key] else { return false }
            entry.timer = number
            byKey[key] = entry
            return true
        }
        guard ok else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, entries.withLock({ $0[key]?.timer == number }) else { return }   // stopped, or read since
            read(key)
        }
    }

    private func read(_ key: Key) {
        let go = entries.withLock { byKey -> (Date, Int, Topic?)? in
            guard var entry = byKey[key] else { return nil }
            if entry.reading {
                entry.again = true
                byKey[key] = entry
                return nil
            }
            entry.reading = true
            entry.timer = nil
            byKey[key] = entry
            return (entry.fastUntil, entry.number, entry.topic)
        }
        guard let (fastUntil, number, topic) = go else { return }
        Task {
            let began = Date()
            let (line, next) = await topic?.read(fastUntil > Date()) ?? (nil, nil)
            reads.withLock { $0?[key, default: 0] += 1 }
            let ours = entries.withLock { byKey -> (send: Data?, to: Set<Int>, again: Bool, quiet: Int)? in
                // Stopped meanwhile, maybe started again: what it read may be older than the new watch's first value,
                // and the new one keeps its own clock.
                guard var entry = byKey[key], entry.number == number else { return nil }
                entry.reading = false
                let changed = line != nil && line != entry.last
                if changed { entry.last = line }
                entry.quiet = changed ? 0 : entry.quiet + 1
                let again = entry.again
                entry.again = false
                byKey[key] = entry
                return (changed ? line : nil, entry.watchers, again, entry.quiet)
            }
            guard let (send, to, again, quiet) = ours else { return }
            if let send { clients.targets(to).forEach { $0.send(send) } }
            // Files changing all through a read: not back to back, or a large repository's git never stops; and not more than
            // 8 s behind either, or a slow repository's panels stay stale while an agent writes.
            if again {
                schedule(key, after: min(8, max(0.4, 4 * Date().timeIntervalSince(began))))
            } else if let next {
                // A backed-off read lands a little apart from the others': every project's watches start and slow down
                // together, so gh and ssh ran in bursts (10 in one 30 s, then 2 in three minutes).
                let wait =
                    fastUntil > Date() ? next : Self.slowed(next, quiet: quiet, from: topic?.backsOffFrom ?? .infinity)
                schedule(key, after: wait == next ? wait : wait * Double.random(in: 0.8...1.2))
            }
        }
    }

    /// When to read again what's asked over the network (gh, glab, ssh: a clock of `from` or longer) after `quiet` reads
    /// that found nothing new: twice as long each time, so projects nobody is working on stop costing processes, quota
    /// and wake-ups. A change, or a watcher asking again, starts over.
    static func slowed(_ next: TimeInterval, quiet: Int, from: TimeInterval) -> TimeInterval {
        guard next >= from else { return next }
        return min(next * pow(2, Double(min(quiet, 6))), next >= 60 ? next * 8 : 60)
    }
}
