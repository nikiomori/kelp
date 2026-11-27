import AgentData
import Core
import Foundation
import os

/// The conversations read for agents' work maps (`session.work`), each kept with how far it was read, so a growing
/// transcript is read only by what it grew. It lives in memory: the Work panel and the Map tab read while they are on
/// screen, and a daemon that starts again reads each file once more.
final class WorkIndex: Sendable {
    struct Entry: Sendable {
        var log = WorkLog()
        /// Where in the file `log` began: a host's long file is read from its last part.
        var base: UInt64 = 0
        var used = Date()
        var read: UInt64 { base + log.offset }
    }

    private let entries = OSAllocatedUnfairLock<[String: Entry]>(initialState: [:])
    /// One lock per file, held while it is read: a second reader (the watch's pass beside `session.work`) waits for
    /// the first instead of parsing the file from its start too.
    private let reading = OSAllocatedUnfairLock<[String: NSLock]>(initialState: [:])
    // Limit: by files, not bytes; a call is kept small (`WorkLog.add`), so this many stays in tens of MB.
    /// How many files are kept; past it, the ones read longest ago go. A session with dozens of subagents is dozens of
    /// files, and two of them on screen must fit, or each read starts every file again.
    static let limit = 400
    /// How much of a file is read and parsed at once.
    static let piece = 8 << 20
    /// The most of a host's file read the first time, from its end.
    static let hostFirstRead: UInt64 = 16 << 20

    /// How long a file nobody reads stays kept: what the closed panel read goes at the next read of anyone's work.
    static let idle: TimeInterval = 600
    /// Answers kept a moment, so the panel, the Map tab and the watch's pass asking at once read once (an ssh read, a
    /// git diff), by key.
    private let answers = OSAllocatedUnfairLock<[String: (at: Date, value: any Sendable)]>(initialState: [:])

    /// Runs `body` holding `key`'s lock: one reader of a file (or a host session) at a time, the next one waits and
    /// continues from where it got to, instead of reading it again from the start.
    func locked<T>(_ key: String, _ body: () throws -> T) rethrows -> T {
        let lock = lock(key)
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Runs `body` if nobody holds `key`'s lock, else returns nil at once: a reader that would wait on another's ssh
    /// run takes the answer kept instead (`kept`).
    func ifFree<T>(_ key: String, _ body: () throws -> T?) rethrows -> T? {
        let lock = lock(key)
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        return try body()
    }

    /// `key`'s lock, made the first time it is asked for.
    private func lock(_ key: String) -> NSLock {
        reading.withLock { locks in
            if let lock = locks[key] { return lock }
            let lock = NSLock()
            locks[key] = lock
            return lock
        }
    }

    /// The answer kept for `key`, however old.
    func kept<T: Sendable>(_ key: String) -> T? { answers.withLock { $0[key]?.value as? T } }

    /// A host file's entry continued by what the host sent from `start` (its size there `size`): the bytes go on from
    /// where it was read to, else it was rewritten or is another file, and it starts again from `start`.
    static func continued(_ entry: Entry, start: UInt64, size: UInt64, data: Data) -> Entry {
        var entry = entry
        if start != entry.read || size < entry.read {
            entry = Entry()
            entry.base = start
        }
        entry.log.read(data)
        return entry
    }

    /// `make`'s answer for `key`, made again only when the one kept is older than `fresh`.
    func recent<T: Sendable>(_ key: String, fresh: TimeInterval, _ make: () -> T?) -> T? {
        if let kept = answers.withLock({ $0[key] }), Date().timeIntervalSince(kept.at) < fresh,
            let value = kept.value as? T
        {
            return value
        }
        guard let value = make() else { return nil }
        answers.withLock { all in
            all[key] = (Date(), value)
            all = all.filter { Date().timeIntervalSince($0.value.at) < Self.idle }
        }
        return value
    }

    /// The log of a file on this Mac, read up to its end.
    func log(_ url: URL, piece first: Int = WorkIndex.piece) -> WorkLog? {
        locked(url.path) { read(url, piece: first) }
    }

    private func read(_ url: URL, piece first: Int) -> WorkLog? {
        guard let size = Artifacts.fileStat(url.path)?.size else { return nil }
        // Taken out while it grows, so its calls aren't copied (the dictionary would share them).
        var entry = entries.withLock { $0.removeValue(forKey: url.path) } ?? Entry()
        if UInt64(size) < entry.read { entry = Entry() }   // replaced or cut: read it again
        if UInt64(size) > entry.read {
            Log.session.attempt("reading \(url.lastPathComponent)") {
                let handle = try FileHandle(forReadingFrom: url)
                defer { handle.closeQuietly() }
                // A piece at a time, its parse's objects let go after each: a 100 MB transcript read whole held
                // several times its size at once. A line longer than a piece doubles the piece.
                var piece = first
                while entry.read < UInt64(size) {
                    try handle.seek(toOffset: entry.read)
                    guard let data = try handle.read(upToCount: piece), !data.isEmpty else { break }
                    let before = entry.read
                    autoreleasepool { entry.log.read(data) }
                    if entry.read == before {
                        guard data.count == piece else { break }   // the last line isn't whole yet
                        piece *= 2
                    }
                }
            }
        }
        keep(url.path, entry)
        return entry.log
    }

    /// The names kept under `prefix` (a host session's files), without it.
    func keys(prefix: String) -> [String] {
        entries.withLock { $0.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) } }
    }

    /// The entry kept for `key` (a host's file), for a read that continues it.
    func entry(_ key: String) -> Entry { entries.withLock { $0[key] } ?? Entry() }

    func keep(_ key: String, _ entry: Entry) {
        var used = entry
        used.used = Date()
        let kept = used
        let (gone, left) = entries.withLock { all -> ([String], Set<String>) in
            all[key] = kept
            // What nobody read for a while goes, and past the limit the one read longest ago.
            var gone = all.filter { kept.used.timeIntervalSince($0.value.used) > Self.idle }.map(\.key)
            gone.forEach { all[$0] = nil }
            if all.count > Self.limit, let oldest = all.min(by: { $0.value.used < $1.value.used })?.key {
                all[oldest] = nil
                gone.append(oldest)
            }
            return (gone, Set(all.keys))
        }
        guard !gone.isEmpty else { return }
        reading.withLock { locks in
            gone.forEach { locks[$0] = nil }
            // A host session's lock goes with the last of its files (`host:<id>`, its files `host:<id>:<name>`).
            for lock in locks.keys where lock.hasPrefix("host:") && !lock.dropFirst(5).contains(":") {
                if !left.contains(where: { $0.hasPrefix(lock + ":") }) { locks[lock] = nil }
            }
        }
    }
}

extension Conversations {
    /// A remote Claude Code's conversation and its subagents', as the host has them: each file from where it was last
    /// read (`offsets`, by name: "main.<id>", so another conversation is another name, or "agent-<id>"), and the
    /// subagents' `.meta.json`. A long conversation is read from its last `WorkIndex.hostFirstRead` bytes the first
    /// time; a file shorter than where it was read to is read from its start. Uses only an open connection, like
    /// `remoteTail`.
    func remoteWork(of session: Session, offsets: [String: UInt64]) -> [HostFile]? {
        guard session.agent == Session.claudeAgent, let remote = remotes.of(session.cwd), remote.connection != nil
        else { return nil }
        let argv = session.argv
        let id = argv.lastIndex { $0 == "--session-id" || $0 == "--resume" }.flatMap { index in
            index + 1 < argv.count ? argv[index + 1] : nil
        }
        let script = Self.workScript(path: remote.path, id: id, claude: hostClaude.withLock { $0 }, offsets: offsets)
        guard let out = Log.session.attempt("reading \(remote.host)'s work", { try remote.run(script, timeLimit: 30) })
        else { return nil }
        return HostFile.split(out)
    }

    /// The script for sh on the host behind `remoteWork`: each file's `\u{1}name size start` line, then its bytes from
    /// `start`; the subagents' `.meta.json` as `meta:<name>`.
    static func workScript(path: String, id: String?, claude: String, offsets: [String: UInt64]) -> String {
        let known = offsets.filter { $0.key.wholeMatch(of: /(main\.[A-Za-z0-9-]+|agent-[A-Za-z0-9-]+)/) != nil }
        let cases = known.map { "\($0.key)) o=\($0.value);;" }.joined(separator: " ")
        let first = WorkIndex.hostFirstRead
        let read = [
            #"emit() {"#,
            #"  s=$(wc -c <"$1" | tr -d ' ')"#,
            #"  case "$2" in "# + cases + #" *) o=0;; esac"#,
            #"  [ "$s" -lt "$o" ] && o=0"#,
            #"  [ "$o" = 0 ] && [ "$s" -gt \#(first) ] && o=$((s - \#(first)))"#,
            #"  printf '\001%s %s %s\n' "$2" "$s" "$o""#,
            #"  [ "$s" -gt "$o" ] && tail -c +$((o + 1)) "$1""#,
            #"}"#,
            #"emit "$f" "main.$(basename "$f" .jsonl)""#,
            #"for a in "${f%.jsonl}"/subagents/agent-*.jsonl; do"#,
            #"  [ -f "$a" ] || continue"#,
            #"  n=$(basename "$a" .jsonl)"#,
            #"  emit "$a" "$n""#,
            #"  m="${a%.jsonl}.meta.json""#,
            #"  [ -f "$m" ] && printf '\001meta:%s 0 0\n' "$n" && cat "$m" && echo"#,
            #"done"#
        ].joined(separator: "\n")
        let script = [
            remoteFileScript(path: path, id: id, claude: claude),
            #"[ -n "$f" ] && [ -f "$f" ] || exit 0"#, read, "exit 0"
        ].joined(separator: "\n")
        return script
    }

    /// One file a host sent: its name, its size there, where the bytes sent begin, the bytes.
    struct HostFile: Equatable {
        var name: String, size: UInt64, start: UInt64, data: Data

        /// Splits a host's answer at its `\u{1}name size start` headers. JSON lines escape control characters, so the
        /// header's byte can't be in a file's text.
        static func split(_ out: Data) -> [HostFile] {
            var files: [HostFile] = []
            var index = out.startIndex
            while let mark = out[index...].firstIndex(of: 1) {
                if var last = files.popLast() {
                    last.data = out[index..<mark]
                    files.append(last)
                }
                guard let end = out[mark...].firstIndex(of: 10) else { break }
                let head = String(decoding: out[(mark + 1)..<end], as: UTF8.self).split(separator: " ")
                if head.count == 3, let size = UInt64(head[1]), let start = UInt64(head[2]) {
                    files.append(HostFile(name: String(head[0]), size: size, start: start, data: Data()))
                }
                index = end + 1
            }
            if var last = files.popLast() {
                last.data = out[index...]
                files.append(last)
            }
            return files.map { file in
                var file = file
                file.data = Data(file.data)   // its own bytes, indexed from 0
                return file
            }
        }
    }
}
