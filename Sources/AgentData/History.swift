import Core
import Foundation
import os

public enum ClaudeHistory {
    /// Where Claude Code keeps conversations: in its folder (`AgentHome`), as Claude Code itself does.
    public static let defaultRoot = AgentHome.root("claude").appendingPathComponent("projects")

    /// The text of the last assistant message in a Claude Code transcript (read from the file's tail).
    public static func lastReply(transcript url: URL) -> String? {
        Data(tail: 262_144, of: url).flatMap(lastReply(tail:))
    }

    /// The same from a transcript's last bytes, wherever they were read (a remote project's, on its host).
    public static func lastReply(tail data: Data) -> String? {
        for line in data.split(separator: 0x0A).reversed() {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                entry["type"] as? String == "assistant",
                let content = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]]
            else { continue }
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(
                separator: "\n"
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return String(text.prefix(4000)) }
        }
        return nil
    }

    /// Sessions under `root/<encoded-cwd>/<sessionId>.jsonl`, newest first. Subagent transcripts (deeper) are skipped.
    public static func sessions(root: URL = defaultRoot) -> [AgentSessionInfo] {
        let fm = FileManager.default
        return fm.items(in: root)
            .flatMap(fm.items(in:))
            .filter { $0.pathExtension == "jsonl" }
            .compactMap(parse)
            .sorted { $0.updated > $1.updated }
    }

    /// Interactive conversations started in `cwd`; Claude names the folder after the real path with every
    /// non-alphanumeric as "-". `claude -p` runs (entrypoint sdk-…) are left out: no terminal owns them.
    public static func sessions(cwd: String, root: URL = defaultRoot) -> [AgentSessionInfo] {
        FileManager.default.items(in: folder(cwd: cwd, root: root))
            .filter { $0.pathExtension == "jsonl" && !isScripted($0) }.compactMap(parse)
    }

    /// One conversation of `cwd` by its id (waking a pinned session needn't parse every other one); nil if it has none.
    public static func session(id: String, cwd: String, root: URL = defaultRoot) -> AgentSessionInfo? {
        let dir = folder(cwd: cwd, root: root)
        return Set([id, id.lowercased()]).lazy.map { dir.appendingPathComponent($0 + ".jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) && !isScripted($0) }.flatMap(parse)
    }

    /// A conversation's file by its id, whichever folder it was started in; nil if there's none.
    public static func transcript(id: String, root: URL = defaultRoot) -> URL? {
        let folders: [URL]
        do { folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) } catch {
            return nil
        }
        let names = Set([id, id.lowercased()]).map { $0 + ".jsonl" }
        return folders.lazy.flatMap { folder in names.map { folder.appendingPathComponent($0) } }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The folder of `cwd`'s conversations under `root`.
    public static func folder(cwd: String, root: URL = defaultRoot) -> URL {
        let real = Paths.real(cwd) ?? cwd   // "/private" kept, as Claude does
        return root.appendingPathComponent(String(real.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }))
    }

    private static func isScripted(_ url: URL) -> Bool {
        let head = Data(head: 8192, of: url) ?? Data()
        return String(bytes: head, encoding: .utf8)?.contains(#""entrypoint":"sdk-"#) == true
    }

    static func parse(_ url: URL) -> AgentSessionInfo? {
        guard let (lines, covered) = JSONL.headAndTail(url) else { return nil }
        var id: String?, cwd: String?, prompt: String?, summary: String?, aiTitle: String?, custom: String?,
            lastPrompt: String?
        var span = JSONL.Span(), count = 0
        for line in lines {
            guard let object = JSONL.object(line) else { continue }
            id = id ?? object["sessionId"] as? String
            cwd = cwd ?? object["cwd"] as? String
            span.add(JSONL.date(object["timestamp"]))
            switch object["type"] as? String {
            case "summary": summary = object["summary"] as? String ?? summary
            case "custom-title": custom = object["customTitle"] as? String ?? custom
            case "ai-title": aiTitle = object["aiTitle"] as? String ?? aiTitle
            case "last-prompt": lastPrompt = object["lastPrompt"] as? String ?? lastPrompt
            case "assistant": count += 1
            case "user":
                count += 1
                if prompt == nil, object["isMeta"] as? Bool != true, object["isSidechain"] as? Bool != true,
                    let message = object["message"] as? [String: Any]
                {
                    prompt = JSONL.promptText(message["content"])
                }
            default: break
            }
        }
        guard count > 0 else { return nil }
        let (started, updated) = span.orFileDate(url)
        return AgentSessionInfo(
            agent: .claude, id: id ?? url.deletingPathExtension().lastPathComponent, cwd: cwd ?? "",
            title: JSONL.clip(custom ?? summary ?? aiTitle ?? prompt ?? lastPrompt ?? ""), started: started,
            updated: updated,
            messageCount: Int((Double(count) / covered).rounded()), path: url)
    }
}

public enum CodexHistory {
    /// In its folder (`AgentHome`), as Codex itself does.
    public static let defaultRoot = AgentHome.root("codex").appendingPathComponent("sessions")

    /// Sessions from `root/YYYY/MM/DD/rollout-*.jsonl`, newest first.
    public static func sessions(root: URL = defaultRoot) -> [AgentSessionInfo] {
        rollouts(root).compactMap(parse).sorted { $0.updated > $1.updated }
    }

    /// What the conversation in `rollout` ended its last turn with; nil before one ended, or if it ended with nothing to say.
    public static func lastReply(rollout url: URL) -> String? {
        for line in JSONL.headAndTail(url)?.lines.reversed() ?? [] {
            guard let payload = JSONL.object(line)?["payload"] as? [String: Any],
                payload["type"] as? String == "task_complete"
            else { continue }
            let text = (payload["last_agent_message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
        return nil
    }

    /// For one that isn't running any more, which no open file names: the newest conversation begun in `cwd` since `since`
    /// with a finished turn.
    /// Limit: two Codex chats begun in one folder can read each other's here, and a resumed one, begun before `since`, reads none.
    public static func lastReply(cwd: String, since: Date, now: Date = Date(), root: URL = defaultRoot) -> String? {
        rollouts(cwd: cwd, since: since, now: now, root: root).compactMap(lastReply(rollout:)).first
    }

    /// The conversations begun in `cwd` since `since`, newest first (same limit as `lastReply(cwd:since:)`).
    public static func rollouts(cwd: String, since: Date, now: Date = Date(), root: URL = defaultRoot)
        -> LazyFilterSequence<[URL]>
    {
        let real = Paths.real(cwd) ?? cwd
        return rollouts(root: root, since: since, now: now).lazy.filter {
            parse($0).map { (Paths.real($0.cwd) ?? $0.cwd) == real } ?? false
        }
    }

    /// Those begun since `since`, newest first: a file's name says when, in local time, like its folder's.
    private static func rollouts(root: URL, since: Date, now: Date) -> [URL] {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy/MM/dd"
        let found = Set([since, now].map(stamp.string)).flatMap { rollouts(root.appendingPathComponent($0)) }
        stamp.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let first = "rollout-" + stamp.string(from: since)
        return found.filter { $0.lastPathComponent >= first }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func rollouts(_ root: URL) -> [URL] {
        let all =
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])?
            .allObjects as? [URL] ?? []
        return all.filter { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" }
    }

    static func parse(_ url: URL) -> AgentSessionInfo? {
        guard let (lines, covered) = JSONL.headAndTail(url) else { return nil }
        var id: String?, cwd: String?, prompt: String?, fallbackPrompt: String?
        var span = JSONL.Span(), count = 0
        for line in lines {
            guard let object = JSONL.object(line), let payload = object["payload"] as? [String: Any] else { continue }
            span.add(JSONL.date(object["timestamp"]))
            switch (object["type"] as? String, payload["type"] as? String) {
            case ("session_meta", _):
                id = id ?? payload["id"] as? String
                cwd = cwd ?? payload["cwd"] as? String
                span.add(JSONL.date(payload["timestamp"]))
            case ("turn_context", _): cwd = cwd ?? payload["cwd"] as? String
            case ("event_msg", "user_message"): prompt = prompt ?? JSONL.promptText(payload["message"])
            case ("response_item", "message"):
                let role = payload["role"] as? String
                guard role == "user" || role == "assistant" else { break }
                count += 1
                if role == "user", fallbackPrompt == nil { fallbackPrompt = JSONL.promptText(payload["content"]) }
            default: break
            }
        }
        guard id != nil || count > 0 else { return nil }
        let (started, updated) = span.orFileDate(url)
        return AgentSessionInfo(
            agent: .codex, id: id ?? String(url.deletingPathExtension().lastPathComponent.suffix(36)), cwd: cwd ?? "",
            title: JSONL.clip(prompt ?? fallbackPrompt ?? ""), started: started, updated: updated,
            messageCount: Int((Double(count) / covered).rounded()), path: url)
    }
}

/// pi's (and oh-my-pi's) conversations: `root/--<real cwd, "/" as "-">--/<time>_<id>.jsonl`, as pi names them.
/// oh-my-pi names a folder in the home folder by its path from there: `-projects-app` (its old `--…--` ones it moves).
public enum PiHistory {
    /// The conversation pi writes under `id` (`--session-id`), in whichever folder: none before its first message.
    public static func file(id: String, root: URL) -> URL? {
        let suffix = "_\(id.lowercased()).jsonl"
        return folders(root).lazy.compactMap { folder in
            (FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: nil, options: .skipsSubdirectoryDescendants)?
                .allObjects as? [URL])?.first { $0.lastPathComponent.lowercased().hasSuffix(suffix) }
        }.first
    }

    /// Grok's conversation `id` (`--session-id`): `root/<folder, percent-encoded>/<id>/`, none before its first
    /// message.
    public static func grokHas(id: String, root: URL) -> Bool {
        folders(root).contains {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(id.lowercased()).path)
        }
    }

    private static func folders(_ root: URL) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        } catch {
            return []   // no folder yet: no conversation either
        }
    }

    /// The one of `cwd` written to last, if that was since `since`.
    /// Limit: two pi chats in one folder read as the one written to last; oh-my-pi's in $TMPDIR (`-tmp-…`) aren't
    /// found.
    public static func newest(
        cwd: String, since: Date, root: URL, home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> URL? {
        let real = Paths.real(cwd) ?? cwd, ownHome = (Paths.real(home) ?? home) + "/"
        func dashed(_ path: Substring) -> String { String(path).replacing(/[\/:]/, with: "-") }
        var names = ["--" + dashed(real.dropFirst(real.hasPrefix("/") ? 1 : 0)) + "--"]
        if real.hasPrefix(ownHome) { names.append("-" + dashed(real.dropFirst(ownHome.count))) }
        func modified(_ url: URL) -> Date {
            var info = stat()
            return stat(url.path, &info) == 0
                ? Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)) : .distantPast
        }
        // No folder: no conversation of pi's here yet.
        let files = names.flatMap { name in
            FileManager.default.enumerator(
                at: root.appendingPathComponent(name), includingPropertiesForKeys: nil,
                options: .skipsSubdirectoryDescendants)?
                .allObjects as? [URL] ?? []
        }
        return files.filter { $0.pathExtension == "jsonl" && modified($0) >= since }.max { modified($0) < modified($1) }
    }
}

public enum History {
    /// Title / cwd substring match; an empty query returns everything.
    public static func search(_ sessions: [AgentSessionInfo], query: String) -> [AgentSessionInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sessions }
        return sessions.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed) || $0.cwd.localizedCaseInsensitiveContains(trimmed)
        }
    }

    // Limit: byte match, so other casings and JSON-escaped text (quotes, newlines) miss; decode + normalize if that bites.
    /// Sessions whose transcript bytes contain `query` (as typed or lowercased), reading at most 2 MB per file.
    public static func fullTextSearch(query: String, in sessions: [AgentSessionInfo], limit: Int = 50)
        -> [AgentSessionInfo]
    {
        let needles = Set([query, query.lowercased()]).filter { !$0.isEmpty }.map { Data($0.utf8) }
        guard !needles.isEmpty else { return [] }
        var out: [AgentSessionInfo] = []
        for session in sessions where out.count < limit {
            if let data = Data(head: 2 << 20, of: session.path), needles.contains(where: { data.range(of: $0) != nil })
            {
                out.append(session)
            }
        }
        return out
    }
}

/// Shared JSONL plumbing. Files are only ever opened for reading.
enum JSONL {
    static let chunk = 64 * 1024

    /// Complete lines from the first and last `chunk` bytes (or the whole file if small) and the fraction of bytes read.
    /// nil for an empty file, or one that can't be read (logged).
    static func headAndTail(_ url: URL) -> (lines: [Data], covered: Double)? {
        Logger.kelp("history").attempt("reading \(url.lastPathComponent)") { try readHeadAndTail(url) } ?? nil
    }

    private static func readHeadAndTail(_ url: URL) throws -> (lines: [Data], covered: Double)? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeQuietly() }
        let size = try handle.seekToEnd()
        guard size > 0 else { return nil }
        try handle.seek(toOffset: 0)
        if size <= UInt64(chunk * 2) { return (lines(try handle.readToEnd() ?? Data()), 1) }
        let head = try handle.read(upToCount: chunk) ?? Data()
        // The last lines can be huge (a tool result, an image): read further back until a few whole lines are in.
        let limit = min(size - UInt64(chunk), 16 << 20)
        var back = UInt64(chunk), tail = Data()
        while true {
            try handle.seek(toOffset: size - back)
            tail = try handle.readToEnd() ?? Data()
            if lines(tail).count > 4 || back >= limit { break }
            back = min(back * 4, limit)
        }
        let headLines = head.last == 10 ? lines(head) : Array(lines(head).dropLast())
        return (headLines + lines(tail).dropFirst(), Double(UInt64(chunk) + back) / Double(size))
    }

    /// Non-empty lines as slices of `data`. memchr, because `Data.split` is ~10x slower on gigabytes of transcripts.
    static func lines(_ data: Data) -> [Data] {
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return [] }
            var out: [Data] = [], start = 0
            while start < buf.count {
                let end = memchr(base + start, 10, buf.count - start).map { base.distance(to: $0) } ?? buf.count
                if end > start { out.append(data[data.startIndex + start..<data.startIndex + end]) }
                start = end + 1
            }
            return out
        }
    }

    static func object(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// A number field as an Int, 0 when it's missing.
    static func int(_ object: [String: Any], _ key: String) -> Int { (object[key] as? NSNumber)?.intValue ?? 0 }

    /// ISO-8601 string (with or without fractional seconds) or epoch seconds.
    static func date(_ value: Any?) -> Date? {
        if let seconds = value as? NSNumber { return Date(timeIntervalSince1970: seconds.doubleValue) }
        return (value as? String).flatMap(CIRuns.date)
    }

    /// Text a human typed: a string or the text blocks of a content array, minus injected `<tag>` and AGENTS.md blocks.
    /// A slash command with arguments counts as "/name args".
    static func promptText(_ content: Any?) -> String? {
        let texts: [String] =
            if let string = content as? String { [string] } else {
                (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            }
        return texts.lazy.compactMap { raw -> String? in
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("<command-"), let name = text.firstMatch(of: /<command-name>(.*?)<\/command-name>/)?.1,
                let args = text.firstMatch(of: /<command-args>([\s\S]*?)<\/command-args>/)?.1,
                !args.allSatisfy(\.isWhitespace)
            {
                return "\(name) \(args)"
            }
            return text.isEmpty || text.hasPrefix("<") || text.hasPrefix("# AGENTS.md") ? nil : text
        }.first
    }

    static func clip(_ text: String, _ length: Int = 80) -> String {
        let oneLine = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return oneLine.count > length ? String(oneLine.prefix(length - 1)) + "…" : oneLine
    }

    struct Span {
        var first: Date?, last: Date?
        mutating func add(_ date: Date?) {
            guard let date else { return }
            first = min(first ?? date, date)
            last = max(last ?? date, date)
        }
        func orFileDate(_ url: URL) -> (Date, Date) {
            let modified =
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date(timeIntervalSince1970: 0)
            return (first ?? modified, last ?? modified)
        }
    }
}
