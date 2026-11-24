import Core
import Foundation
import GitKit
import os

/// What clients watch (`watch.start` and `watch.stop`, below; what each topic reads is in WatchHandlers.swift). A topic
/// and key is read only while someone watches it, once for all watchers, and pushed to them when it changed: the first
/// value right away, and the last one to whoever joins later.
/// A git topic is read when its folder's files change (through FSEvents here, not one watcher per panel in the app);
/// the other topics are read on their own clock, which each read sets (CI keeps reading only while a run goes on). A
/// connection that goes away stops watching.
final class Watches: Sendable {
    struct Key: Hashable, Sendable { let topic: WatchTopic, key: String }
    private struct Entry {
        let number: Int   // numbers this watch, so a read begun for a watch stopped since says nothing to the next
        var watchers: Set<Int>
        var last: Data?   // the event as last sent (sorted keys); the next is sent only when it differs
        var reading = false, again = false
        var timer: Int?   // the scheduled read's number; a newer one (or none) makes it a no-op
        var files: FileStreams.Hold?
        var fastUntil = Date.distantPast
        var tag: String?   // for the context topic: the session's status at the last read
        var quiet = 0   // reads in a row that found nothing new
        var topic: Topic?   // the topic, asked for once as the watch begins
        var failure: String?   // why its last read failed, as the log said it
    }
    private let entries = OSAllocatedUnfairLock<[Key: Entry]>(initialState: [:])
    private let closed = OSAllocatedUnfairLock(initialState: false)
    /// Watches running now (tests).
    var count: Int { entries.withLock { $0.count } }
    private let numbers = OSAllocatedUnfairLock(initialState: 0)   // numbers for watches and scheduled reads
    /// Reads so far, by key, counted once a test sets this to `[:]` (to check one read for two watchers, and none after
    /// the last one left). It stays nil while the daemon runs, because a count for every key ever watched would only
    /// grow.
    let reads = OSAllocatedUnfairLock<[Key: Int]?>(initialState: nil)
    /// What a topic is. `folder` is the folder whose file events can change it, and which of those events do. `read`
    /// reads it now and returns the event as sent (nil when there's nothing to say) and when to read it again if
    /// nothing else says so (nil means only when something does). `backsOffFrom` is the clock from which its reads back
    /// off while nothing changes (`slowed`).
    struct Topic: Sendable {
        var folder: (String, @Sendable ([FileWatcher.Change]) -> Bool)?
        var backsOffFrom = TimeInterval.infinity
        var read: @Sendable (_ fast: Bool) async -> (Data?, TimeInterval?)
    }
    /// The function that gives each key its topic. The daemon sets it once it is made (`Daemon.topic`, one switch for
    /// every topic, which answers the topics' methods the way a client would); a test can set a stand-in instead, for
    /// example to hold one read back while a newer one finishes. It sits in a struct rather than bare in the lock: see
    /// `Store.Listener`.
    struct Reading: Sendable { var topic: (@Sendable (Key) -> Topic)? }
    let reading = OSAllocatedUnfairLock(initialState: Reading())
    private let clients: Clients
    /// The FSEvents streams the watches' folders share.
    let streams = FileStreams()

    init(clients: Clients) { self.clients = clients }

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
        // If the daemon stopped every watch while this one was being added, this one goes too, rather than run on
        // unseen.
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
        _ = gone   // its scheduled read finds it gone; its hold on a file stream goes with it
    }

    /// Stops every watch of a connection that went away.
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
        _ = gone   // released here, out of the lock: their holds on file streams go with them
    }

    func stopAll() {
        closed.withLock { $0 = true }
        let all = entries.withLock { byKey in
            defer { byKey = [:] }
            return byKey
        }
        _ = all   // released off the lock (a file watch's deinit waits on its own queue)
    }

    /// Records that a read of `key` failed. It goes in the log when its reason is new for this watch, not again at
    /// every read.
    func failed(_ key: Key, _ reason: String) {
        let new = entries.withLock { byKey -> Bool in
            guard byKey[key] != nil, byKey[key]?.failure != reason else { return false }
            byKey[key]?.failure = reason
            return true
        }
        if new {
            Log.rpc.error(
                "watching \(key.topic.rawValue, privacy: .public) \(key.key, privacy: .public): \(reason, privacy: .public)"
            )
        }
    }

    /// Reads `key` again when `tag` differs from the last one, because something says it may have changed (a session's
    /// status, for its context).
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
            // File events are debounced, because a save is several events and a checkout hundreds. They arrive on a
            // queue of their own (`FileStreams`).
            let hold = streams.hold(root) { [weak self] changes in
                guard let self, matters(changes) else { return }
                soon(key)
            }
            entries.withLock { byKey in byKey[key]?.files = hold }
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
                // If the watch stopped meanwhile, and maybe started again, this read may be older than the new watch's
                // first value, and the new watch keeps its own clock.
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
            // When files kept changing during a read, the next read doesn't come back to back, or a large repository's
            // git never stops. It isn't more than 8 s behind either, or a slow repository's panels stay stale while an
            // agent writes.
            if again {
                schedule(key, after: min(8, max(0.4, 4 * Date().timeIntervalSince(began))))
            } else if let next {
                // A backed-off read lands a little apart from the others, because every project's watches start and
                // slow down together, so gh and ssh ran in bursts (10 in one 30 s, then 2 in three minutes).
                let wait =
                    fastUntil > Date() ? next : Self.slowed(next, quiet: quiet, from: topic?.backsOffFrom ?? .infinity)
                schedule(key, after: wait == next ? wait : wait * Double.random(in: 0.8...1.2))
            }
        }
    }

    /// When to read again a topic asked over the network (gh, glab, ssh: a clock of `from` or longer) after `quiet`
    /// reads that found nothing new. The wait doubles each time, so projects nobody is working on stop costing
    /// processes, quota and wake-ups. A change, or a watcher asking again, starts over.
    static func slowed(_ next: TimeInterval, quiet: Int, from: TimeInterval) -> TimeInterval {
        guard next >= from else { return next }
        return min(next * pow(2, Double(min(quiet, 6))), next >= 60 ? next * 8 : 60)
    }
}

extension WatchStart: Handled {
    static let agents = AgentAccess.reads
    static var inOrder: Bool { true }   // a start and a stop sent in a row apply in that order
    /// A topic reads as the user (`ask`), so each topic says whether an agent may watch it, and a new topic is decided
    /// here, not let through by default. The topics agents watch read only what agents may read themselves
    /// (`AgentAccess.reads`, a file's problems). The databases topic is the window's view, with hidden databases, All
    /// My Projects (hosts, users, keychain items) and the user's own statements. An agent asks `db.list` and `db.query`
    /// instead, which say what it may see.
    var fence: Fence { Fence(notForAgents: refusal) }
    private var refusal: String? {
        switch topic {
        case .databases: "The databases' activity is the user's: `kelp db list` says which an agent may use."
        case .phone: "The phones and their pairing link are the user's."
        case .git, .ports, .activity, .ci, .pr, .context, .limits, .commands, .subagents, .edits, .file, .files, .host,
            .hostDetail, .machines, .machineDetail, .artifacts, .prs, .work:
            nil
        }
    }
    func handle(_ watches: Watches, conn: Int) throws -> Done {
        watches.start(.init(topic: topic, key: key), conn: conn)
        return Done()
    }
}

extension WatchStop: Handled {
    static let agents = AgentAccess.reads
    static var inOrder: Bool { true }
    func handle(_ watches: Watches, conn: Int) throws -> Done {
        watches.stop(.init(topic: topic, key: key), conn: conn)
        return Done()
    }
}

extension Methods {
    static let watchMethods: [any Answered.Type] = [WatchStart.self, WatchStop.self]
}

/// Lets a watch's first read through once. It reads what someone just put on screen, so it may connect to a host
/// (`mayRead`).
final class FirstRead: Sendable {
    private let left = OSAllocatedUnfairLock(initialState: true)
    func take() -> Bool {
        left.withLock {
            defer { $0 = false }
            return $0
        }
    }
}

/// A git watch's last `branchWork`, and the branches it was read for.
final class BranchMemo: Sendable {
    struct Seen: Equatable, Sendable {
        var branches: BranchInfo, base: String?, branch: String
    }
    typealias Work = (files: [String]?, only: Int?)
    private let last = OSAllocatedUnfairLock<(seen: Seen, work: Work)?>(initialState: nil)
    func known(_ seen: Seen) -> Work? { last.withLock { $0.flatMap { $0.seen == seen ? $0.work : nil } } }
    func keep(_ seen: Seen, _ work: Work) { last.withLock { $0 = (seen, work) } }
}
