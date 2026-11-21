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
    /// How many files are kept; past it, the ones read longest ago go.
    static let limit = 48
    /// The most of a host's file read the first time, from its end.
    static let hostFirstRead: UInt64 = 16 << 20

    /// The log of a file on this Mac, read up to its end.
    func log(_ url: URL) -> WorkLog? {
        guard let size = Artifacts.fileStat(url.path)?.size else { return nil }
        var entry = entries.withLock { $0[url.path] } ?? Entry()
        if UInt64(size) < entry.read { entry = Entry() }   // replaced or cut: read it again
        if UInt64(size) > entry.read {
            let from = entry.read
            let grown = Log.session.attempt("reading \(url.lastPathComponent)") { () throws -> Data? in
                let handle = try FileHandle(forReadingFrom: url)
                defer { handle.closeQuietly() }
                try handle.seek(toOffset: from)
                return try handle.readToEnd()
            }
            if let grown, let data = grown { entry.log.read(data) }
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
        entries.withLock { all in
            all[key] = kept
            if all.count > Self.limit, let oldest = all.min(by: { $0.value.used < $1.value.used })?.key {
                all[oldest] = nil
            }
        }
    }
}

extension Conversations {
    /// A remote Claude Code's conversation and its subagents', as the host has them: each file from where it was last
    /// read (`offsets`, by name: "main" or "agent-<id>"), and the subagents' `.meta.json`. A long conversation is read
    /// from its last `WorkIndex.hostFirstRead` bytes the first time. Uses only an open connection, like `remoteTail`.
    func remoteWork(of session: Session, offsets: [String: UInt64]) -> [HostFile]? {
        guard session.agent == Session.claudeAgent, let remote = remotes.of(session.cwd), remote.connection != nil
        else { return nil }
        let argv = session.argv
        let id = argv.lastIndex { $0 == "--session-id" || $0 == "--resume" }.flatMap { index in
            index + 1 < argv.count ? argv[index + 1] : nil
        }
        let known = offsets.filter { $0.key.wholeMatch(of: /(main|agent-[A-Za-z0-9]+)/) != nil }
        let cases = known.map { "\($0.key)) o=\($0.value);;" }.joined(separator: " ")
        let first = WorkIndex.hostFirstRead
        let read = [
            #"emit() {"#,
            #"  s=$(wc -c <"$1" | tr -d ' ')"#,
            #"  case "$2" in "# + cases + #" *) o=0;; esac"#,
            #"  [ "$o" = 0 ] && [ "$s" -gt \#(first) ] && o=$((s - \#(first)))"#,
            #"  printf '\001%s %s %s\n' "$2" "$s" "$o""#,
            #"  [ "$s" -gt "$o" ] && tail -c +$((o + 1)) "$1""#,
            #"}"#,
            #"emit "$f" main"#,
            #"for a in "${f%.jsonl}"/subagents/agent-*.jsonl; do"#,
            #"  [ -f "$a" ] || continue"#,
            #"  n=$(basename "$a" .jsonl)"#,
            #"  emit "$a" "$n""#,
            #"  m="${a%.jsonl}.meta.json""#,
            #"  [ -f "$m" ] && printf '\001meta:%s 0 0\n' "$n" && cat "$m" && echo"#,
            #"done"#
        ].joined(separator: "\n")
        let script = [
            Self.remoteFileScript(path: remote.path, id: id, claude: hostClaude.withLock { $0 }),
            #"[ -n "$f" ] && [ -f "$f" ] || exit 0"#, read, "exit 0"
        ].joined(separator: "\n")
        guard let out = Log.session.attempt("reading \(remote.host)'s work", { try remote.run(script, timeLimit: 30) })
        else { return nil }
        return HostFile.split(out)
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
