import Core
import Foundation
import os

private let usageLog = Logger.kelp("usage")

/// What an agent used (Claude Code, or another `UsageFormat`), by local day, model and folder, kept up to date cheaply: each
/// log is read once, then only the bytes appended since (the index remembers how far it got, on disk). Claude's lines are
/// not parsed whole: only their small `usage` object and a few fields are, so gigabytes take seconds the first time.
public final class UsageIndex: Sendable {
    public struct Tally: Codable, Sendable, Equatable {
        public var tokens = TokenCounts()
        public var cost = 0.0
    }
    struct FileState: Codable, Sendable {
        var offset: UInt64
        var born: Double
        var tallies: [String: Tally] = [:]   // "day|model|cwd"
        /// The last day by UTC hour and model ("epoch|model"), for the 5-hour block. nil: indexed before it existed (read again).
        var hours: [String: Tally]? = [:]
        /// The last responses' ids: one response is several lines, which can straddle two reads.
        var recent: [String]? = []
        /// What earlier lines said that later ones need (`UsageFormat.entry`); nil before the first read.
        var context: [String: String]?
    }
    public struct Row: Sendable {
        public var day: String, model: String, cwd: String
        public var tally: Tally
    }

    /// Calls read some other way (Copilot's database) as rows, by local day, model and folder.
    static func rows(_ entries: [UsageEntry]) -> [Row] {
        var tallies: [String: Row] = [:]
        for entry in entries {
            let date = day(entry.time), key = "\(date)|\(entry.model)|\(entry.cwd)"
            tallies[key, default: Row(day: date, model: entry.model, cwd: entry.cwd, tally: Tally())].tally.tokens +=
                entry.tokens
            tallies[key]?.tally.cost += entry.cost ?? Pricing.cost(model: entry.model, tokens: entry.tokens)
        }
        return Array(tallies.values)
    }
    public struct Hour: Sendable {
        public var start: Date, model: String
        public var tally: Tally
    }

    private let cacheURL: URL
    private let format: UsageFormat
    /// Path → what's been read of it. Updates hold the lock while they read (one at a time: the first one reads gigabytes).
    private let files: OSAllocatedUnfairLock<[String: FileState]>
    /// The index on disk may lag this much (it's megabytes, and some log always grew): a crash only reads those bytes again.
    private static let saveEvery: TimeInterval = 600
    private let saved = OSAllocatedUnfairLock(initialState: (at: Date.distantPast, pending: false))

    public init(cache: URL, format: UsageFormat = .claude) {
        cacheURL = cache
        self.format = format
        files = OSAllocatedUnfairLock(
            initialState: Data(contentsIfAny: cache).flatMap { data in
                usageLog.attempt("reading the usage index") {
                    try JSONDecoder().decode([String: FileState].self, from: data)
                }
            } ?? [:])
    }

    /// Reads what's new in transcripts under `roots` changed since `since`, then everything known from `since` on.
    public func rows(roots: [URL], since: Date) -> [Row] {
        let first = Self.day(since)
        return files.withLock { update(&$0, roots: roots, since: since) }.flatMap { $0.tallies }.compactMap {
            key, tally in
            let parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            return parts.count == 3 && parts[0] >= first
                ? Row(day: parts[0], model: parts[1], cwd: parts[2], tally: tally) : nil
        }
    }

    /// The 5-hour block `now` falls in (nil when the last one reset), from transcripts changed in the last 10 hours.
    /// `fresh`: `rows` just read them, from at least that far back: a walk of the folder is not done twice.
    public func currentBlock(roots: [URL], now: Date = Date(), fresh: Bool = false) -> ClaudeUsage.Block? {
        let since = now.addingTimeInterval(-10 * 3600).timeIntervalSince1970
        let hours = files.withLock {
            fresh ? Self.under(roots, $0) : update(&$0, roots: roots, since: Date(timeIntervalSince1970: since))
        }
        .flatMap { $0.hours ?? [:] }.compactMap { key, tally -> Hour? in
            let parts = key.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let hour = Double(parts[0]), hour > since - 3600 else { return nil }
            return Hour(start: Date(timeIntervalSince1970: hour), model: String(parts[1]), tally: tally)
        }
        return Self.block(hours, now: now)
    }

    /// ccusage's rule over hourly sums: a block starts at the first hour used and lasts 5 h; the first hour past that
    /// starts the next one.
    public static func block(_ hours: [Hour], now: Date) -> ClaudeUsage.Block? {
        var start: Date?, inBlock: [Hour] = []
        for hour in hours.sorted(by: { $0.start < $1.start }) where hour.start <= now {
            if let blockStart = start, hour.start < blockStart + ClaudeUsage.blockLength {
                inBlock.append(hour)
                continue
            }
            start = hour.start
            inBlock = [hour]
        }
        guard let blockStart = start, now < blockStart + ClaudeUsage.blockLength else { return nil }
        return ClaudeUsage.Block(
            start: blockStart, end: blockStart + ClaudeUsage.blockLength,
            tokens: inBlock.reduce(TokenCounts()) { $0 + $1.tally.tokens },
            estimatedCostUSD: inBlock.reduce(0) { $0 + $1.tally.cost }, models: Set(inBlock.map(\.model)).sorted())
    }

    /// Reads what's new in transcripts under `roots` changed since `since` into `known`; the states of the files under them.
    private func update(_ known: inout [String: FileState], roots: [URL], since: Date) -> [FileState] {
        var changed = false
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey, .fileSizeKey]
        for root in roots {
            for case let file as URL in FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Array(keys))
                ?? NSEnumerator()
            where format.reads(file) {
                guard let values = try? file.resourceValues(forKeys: keys),
                    (values.contentModificationDate ?? .distantPast) >= since
                else { continue }
                let size = UInt64(values.fileSize ?? 0)
                var st =
                    known[file.path]
                    ?? FileState(offset: 0, born: (values.creationDate ?? .distantPast).timeIntervalSince1970)
                if size < st.offset || st.hours == nil { st = FileState(offset: 0, born: st.born) }   // rewritten, or indexed without hours
                guard size > st.offset else { continue }
                Self.read(file, into: &st, format: format)
                known[file.path] = st
                changed = true
            }
        }
        let save = saved.withLock { [changed] state -> Bool in
            state.pending = state.pending || changed
            guard state.pending, Date().timeIntervalSince(state.at) >= Self.saveEvery else { return false }
            state = (Date(), false)
            return true
        }
        if save {
            usageLog.attempt("saving the usage index") {
                try JSONEncoder().encode(known).write(to: cacheURL, options: .atomic)
            }
        }
        return Self.under(roots, known)
    }

    /// The files under `roots` alone (one account's). The enumerator may report /private/var/… for /var/… (and the other way round).
    private static func under(_ roots: [URL], _ known: [String: FileState]) -> [FileState] {
        func plain(_ path: String) -> String {
            path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
        }
        let prefixes = roots.map { plain($0.path) + "/" }
        return known.filter { path, _ in prefixes.contains { plain(path).hasPrefix($0) } }.map(\.value)
    }

    /// Days `from`…`to` (local, inclusive) as one block: what Usage's "today" and "this week" show.
    public static func block(_ rows: [Row], from: Date, to: Date) -> ClaudeUsage.Block {
        let first = day(from), last = day(to)
        let in_ = rows.filter { $0.day >= first && $0.day <= last }
        return ClaudeUsage.Block(
            start: from, end: to, tokens: in_.reduce(TokenCounts()) { $0 + $1.tally.tokens },
            estimatedCostUSD: in_.reduce(0) { $0 + $1.tally.cost }, models: Set(in_.map(\.model)).sorted())
    }

    /// The complete lines after `offset`, 8 MB at a time (one session can be gigabytes); a line still being written waits
    /// for next time.
    static func read(_ url: URL, into st: inout FileState, format: UsageFormat = .claude) {
        let offset = st.offset
        guard
            let handle = usageLog.attempt(
                "opening \(url.lastPathComponent)",
                { () throws -> FileHandle in
                    let handle = try FileHandle(forReadingFrom: url)
                    try handle.seek(toOffset: offset)
                    return handle
                })
        else { return }
        defer { handle.closeQuietly() }
        var recent = st.recent ?? [], seen = Set(recent), hours = st.hours ?? [:], rest = Data()
        var context = st.context ?? format.start(url)
        while let chunk = autoreleasepool(invoking: {
            usageLog.attempt("reading") { try handle.read(upToCount: 8 << 20) }
        })
            ?? nil, !chunk.isEmpty
        {
            let data = rest.isEmpty ? chunk : rest + chunk
            guard let last = data.lastIndex(of: 0x0A) else {
                rest = data
                continue
            }
            for line in JSONL.lines(data[..<last]) where format.markers.contains(where: { line.range(of: $0) != nil }) {
                // Older than the file: history a resumed (or forked) session copied in.
                guard let entry = format.entry(line, &context), entry.time >= st.born - 120 else { continue }
                if let id = entry.id {
                    guard seen.insert(id).inserted else { continue }
                    recent.append(id)
                }   // one response, several lines
                let cost = entry.cost ?? Pricing.cost(model: entry.model, tokens: entry.tokens)
                func add(_ tally: inout Tally) {
                    tally.tokens += entry.tokens
                    tally.cost += cost
                }
                add(&st.tallies["\(day(entry.time))|\(entry.model)|\(entry.cwd)", default: Tally()])
                add(&hours["\(Int(entry.time / 3600) * 3600)|\(entry.model)", default: Tally()])
            }
            st.offset += UInt64(last - data.startIndex + 1)
            rest = Data(data[(last + 1)...])
        }
        let dayAgo = Date().timeIntervalSince1970 - 86400
        st.hours = hours.filter { (Double($0.key.prefix { $0 != "|" }) ?? 0) >= dayAgo }
        st.recent = Array(recent.suffix(64))
        st.context = context
    }

    /// One assistant line's numbers, without parsing its (large) message content.
    static func entry(_ line: Data) -> UsageEntry? {
        // `"type":"assistant"` is the line's own type; the first "type" in a line is usually the message's ("message").
        guard line.range(of: assistant) != nil, let usage = object(line, after: "\"usage\":"),
            let counts = try? JSONSerialization.jsonObject(with: usage) as? [String: Any],
            let ts = JSONL.date(field(line, "timestamp"))?.timeIntervalSince1970
        else { return nil }
        let model = field(line, "model") ?? "unknown"
        guard model != "<synthetic>" else { return nil }
        func n(_ key: String) -> Int { (counts[key] as? NSNumber)?.intValue ?? 0 }
        let id = [field(line, "id"), field(line, "requestId")].compactMap { $0 }.joined(separator: ":")
        let tokens = TokenCounts(
            input: n("input_tokens"), output: n("output_tokens"), cacheWrite: n("cache_creation_input_tokens"),
            cacheRead: n("cache_read_input_tokens"))
        let hourWrites =
            ((counts["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue ?? 0
        return UsageEntry(
            time: ts, model: model, cwd: field(line, "cwd") ?? "", id: id.isEmpty ? nil : id, tokens: tokens,
            cost: Pricing.cost(model: model, tokens: tokens, hourWrites: hourWrites))
    }

    /// The first `"name":"value"` in the line (string values only).
    static func field(_ line: Data, _ name: String) -> String? {
        guard let key = line.range(of: Data("\"\(name)\":\"".utf8)),
            let end = line[key.upperBound...].firstIndex(of: 0x22)
        else { return nil }
        return String(data: line[key.upperBound..<end], encoding: .utf8)
    }

    /// The `{…}` that follows `prefix` (braces counted; the usage object has no strings with braces).
    static func object(_ line: Data, after prefix: String) -> Data? {
        guard let found = line.range(of: Data(prefix.utf8)), line[found.upperBound...].first == 0x7B else { return nil }
        var depth = 0
        for index in found.upperBound..<line.endIndex {
            if line[index] == 0x7B {
                depth += 1
            } else if line[index] == 0x7D {
                depth -= 1
                if depth == 0 { return line[found.upperBound...index] }
            }
        }
        return nil
    }

    static let assistant = Data("\"type\":\"assistant\"".utf8), marker = Data("\"output_tokens\"".utf8)
    static func day(_ time: TimeInterval) -> String { day(Date(timeIntervalSince1970: time)) }
    public static func day(_ date: Date) -> String {
        Date.ISO8601FormatStyle(timeZone: .current).year().month().day().format(date)
    }   // local "yyyy-MM-dd"
}
