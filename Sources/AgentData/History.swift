import Foundation
import Core

public enum ClaudeHistory {
    /// Where Claude Code keeps conversations: under CLAUDE_CONFIG_DIR when it's set, as Claude Code itself does.
    public static let defaultRoot = (ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")).appendingPathComponent("projects")

    /// Sessions under `root/<encoded-cwd>/<sessionId>.jsonl`, newest first. Subagent transcripts (deeper) are skipped.
    public static func sessions(root: URL = defaultRoot) -> [AgentSessionInfo] {
        let fm = FileManager.default
        let projects = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return projects
            .flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { $0.pathExtension == "jsonl" }
            .compactMap(parse)
            .sorted { $0.updated > $1.updated }
    }

    /// Interactive conversations started in `cwd`; Claude names the folder after the real path with every
    /// non-alphanumeric as "-". `claude -p` runs (entrypoint sdk-…) are left out: no terminal owns them.
    public static func sessions(cwd: String, root: URL = defaultRoot) -> [AgentSessionInfo] {
        ((try? FileManager.default.contentsOfDirectory(at: folder(cwd: cwd, root: root), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" && !isScripted($0) }.compactMap(parse)
    }

    /// One conversation of `cwd` by its id (waking a pinned session needn't parse every other one); nil if it has none.
    public static func session(id: String, cwd: String, root: URL = defaultRoot) -> AgentSessionInfo? {
        let dir = folder(cwd: cwd, root: root)
        return Set([id, id.lowercased()]).lazy.map { dir.appendingPathComponent($0 + ".jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) && !isScripted($0) }.flatMap(parse)
    }

    /// The folder of `cwd`'s conversations under `root`.
    public static func folder(cwd: String, root: URL = defaultRoot) -> URL {
        let real = Paths.real(cwd) ?? cwd   // "/private" kept, as Claude does
        return root.appendingPathComponent(String(real.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }))
    }

    private static func isScripted(_ url: URL) -> Bool {
        let head = (try? FileHandle(forReadingFrom: url)).flatMap { h in defer { try? h.close() }; return try? h.read(upToCount: 8192) } ?? Data()
        return String(bytes: head, encoding: .utf8)?.contains(#""entrypoint":"sdk-"#) == true
    }

    static func parse(_ url: URL) -> AgentSessionInfo? {
        guard let (lines, covered) = JSONL.headAndTail(url) else { return nil }
        var id: String?, cwd: String?, prompt: String?, summary: String?, aiTitle: String?, custom: String?, lastPrompt: String?
        var span = JSONL.Span(), count = 0
        for line in lines {
            guard let o = JSONL.object(line) else { continue }
            id = id ?? o["sessionId"] as? String
            cwd = cwd ?? o["cwd"] as? String
            span.add(JSONL.date(o["timestamp"]))
            switch o["type"] as? String {
            case "summary": summary = o["summary"] as? String ?? summary
            case "custom-title": custom = o["customTitle"] as? String ?? custom
            case "ai-title": aiTitle = o["aiTitle"] as? String ?? aiTitle
            case "last-prompt": lastPrompt = o["lastPrompt"] as? String ?? lastPrompt
            case "assistant": count += 1
            case "user":
                count += 1
                if prompt == nil, o["isMeta"] as? Bool != true, o["isSidechain"] as? Bool != true,
                   let m = o["message"] as? [String: Any] { prompt = JSONL.promptText(m["content"]) }
            default: break
            }
        }
        guard count > 0 else { return nil }
        let (started, updated) = span.orFileDate(url)
        return AgentSessionInfo(agent: .claude, id: id ?? url.deletingPathExtension().lastPathComponent, cwd: cwd ?? "",
                                title: JSONL.clip(custom ?? summary ?? aiTitle ?? prompt ?? lastPrompt ?? ""), started: started, updated: updated,
                                messageCount: Int((Double(count) / covered).rounded()), path: url)
    }
}

public enum CodexHistory {
    /// Under CODEX_HOME when it's set, as Codex itself does.
    public static let defaultRoot = (ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")).appendingPathComponent("sessions")

    /// Sessions from `root/YYYY/MM/DD/rollout-*.jsonl`, newest first.
    public static func sessions(root: URL = defaultRoot) -> [AgentSessionInfo] {
        rollouts(root).compactMap(parse).sorted { $0.updated > $1.updated }
    }

    static func rollouts(_ root: URL) -> [URL] {
        let all = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])?.allObjects as? [URL] ?? []
        return all.filter { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" }
    }

    static func parse(_ url: URL) -> AgentSessionInfo? {
        guard let (lines, covered) = JSONL.headAndTail(url) else { return nil }
        var id: String?, cwd: String?, prompt: String?, fallbackPrompt: String?
        var span = JSONL.Span(), count = 0
        for line in lines {
            guard let o = JSONL.object(line), let p = o["payload"] as? [String: Any] else { continue }
            span.add(JSONL.date(o["timestamp"]))
            switch (o["type"] as? String, p["type"] as? String) {
            case ("session_meta", _):
                id = id ?? p["id"] as? String
                cwd = cwd ?? p["cwd"] as? String
                span.add(JSONL.date(p["timestamp"]))
            case ("turn_context", _): cwd = cwd ?? p["cwd"] as? String
            case ("event_msg", "user_message"): prompt = prompt ?? JSONL.promptText(p["message"])
            case ("response_item", "message"):
                let role = p["role"] as? String
                guard role == "user" || role == "assistant" else { break }
                count += 1
                if role == "user", fallbackPrompt == nil { fallbackPrompt = JSONL.promptText(p["content"]) }
            default: break
            }
        }
        guard id != nil || count > 0 else { return nil }
        let (started, updated) = span.orFileDate(url)
        return AgentSessionInfo(agent: .codex, id: id ?? String(url.deletingPathExtension().lastPathComponent.suffix(36)), cwd: cwd ?? "",
                                title: JSONL.clip(prompt ?? fallbackPrompt ?? ""), started: started, updated: updated,
                                messageCount: Int((Double(count) / covered).rounded()), path: url)
    }
}

public enum History {
    /// Title / cwd substring match; an empty query returns everything.
    public static func search(_ sessions: [AgentSessionInfo], query: String) -> [AgentSessionInfo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return sessions }
        return sessions.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.cwd.localizedCaseInsensitiveContains(q) }
    }

    // Limit: byte match, so other casings and JSON-escaped text (quotes, newlines) miss; decode + normalize if that bites.
    /// Sessions whose transcript bytes contain `query` (as typed or lowercased), reading at most 2 MB per file.
    public static func fullTextSearch(query: String, in sessions: [AgentSessionInfo], limit: Int = 50) -> [AgentSessionInfo] {
        let needles = Set([query, query.lowercased()]).filter { !$0.isEmpty }.map { Data($0.utf8) }
        guard !needles.isEmpty else { return [] }
        var out: [AgentSessionInfo] = []
        for s in sessions where out.count < limit {
            guard let h = try? FileHandle(forReadingFrom: s.path) else { continue }
            let data = (try? h.read(upToCount: 2 << 20)) ?? nil
            try? h.close()
            if let data, needles.contains(where: { data.range(of: $0) != nil }) { out.append(s) }
        }
        return out
    }

    public static func resumeCommand(for s: AgentSessionInfo) -> [String] {
        switch s.agent {
        case .claude: ["claude", "--resume", s.id]
        case .codex: ["codex", "resume", s.id]
        }
    }
}

/// Shared JSONL plumbing. Files are only ever opened for reading.
enum JSONL {
    static let chunk = 64 * 1024

    /// Complete lines from the first and last `chunk` bytes (or the whole file if small) and the fraction of bytes read.
    static func headAndTail(_ url: URL) -> (lines: [Data], covered: Double)? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd(), size > 0, (try? h.seek(toOffset: 0)) != nil else { return nil }
        if size <= UInt64(chunk * 2) { return (lines((try? h.readToEnd()) ?? Data()), 1) }
        let head = (try? h.read(upToCount: chunk)) ?? Data()
        // The last lines can be huge (a tool result, an image): read further back until a few whole lines are in.
        let limit = min(size - UInt64(chunk), 16 << 20)
        var back = UInt64(chunk), tail = Data()
        while true {
            guard (try? h.seek(toOffset: size - back)) != nil else { return nil }
            tail = (try? h.readToEnd()) ?? Data()
            if lines(tail).count > 4 || back >= limit { break }
            back = min(back * 4, limit)
        }
        let headLines = head.last == 10 ? lines(head) : Array(lines(head).dropLast())
        return (headLines + lines(tail).dropFirst(), Double(UInt64(chunk) + back) / Double(size))
    }

    /// Non-empty lines as slices of `d`. memchr, because `Data.split` is ~10x slower on gigabytes of transcripts.
    static func lines(_ d: Data) -> [Data] {
        d.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return [] }
            var out: [Data] = [], start = 0
            while start < buf.count {
                let end = memchr(base + start, 10, buf.count - start).map { base.distance(to: $0) } ?? buf.count
                if end > start { out.append(d[d.startIndex + start ..< d.startIndex + end]) }
                start = end + 1
            }
            return out
        }
    }

    static func object(_ d: Data) -> [String: Any]? { try? JSONSerialization.jsonObject(with: d) as? [String: Any] }

    /// A number field as an Int, 0 when it's missing.
    static func int(_ o: [String: Any], _ k: String) -> Int { (o[k] as? NSNumber)?.intValue ?? 0 }

    /// ISO-8601 string (with or without fractional seconds) or epoch seconds.
    static func date(_ v: Any?) -> Date? {
        if let n = v as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
        guard let s = v as? String else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s)) ?? (try? Date.ISO8601FormatStyle().parse(s))
    }

    /// Text a human typed: a string or the text blocks of a content array, minus injected `<tag>` and AGENTS.md blocks.
    /// A slash command with arguments counts as "/name args".
    static func promptText(_ content: Any?) -> String? {
        let texts: [String] = if let s = content as? String { [s] }
            else { (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String } }
        return texts.lazy.compactMap { t -> String? in
            let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("<command-"), let name = s.firstMatch(of: /<command-name>(.*?)<\/command-name>/)?.1,
               let args = s.firstMatch(of: /<command-args>([\s\S]*?)<\/command-args>/)?.1,
               !args.allSatisfy(\.isWhitespace) { return "\(name) \(args)" }
            return s.isEmpty || s.hasPrefix("<") || s.hasPrefix("# AGENTS.md") ? nil : s
        }.first
    }

    static func clip(_ s: String, _ n: Int = 80) -> String {
        let t = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return t.count > n ? String(t.prefix(n - 1)) + "…" : t
    }

    struct Span {
        var first: Date?, last: Date?
        mutating func add(_ d: Date?) {
            guard let d else { return }
            first = min(first ?? d, d); last = max(last ?? d, d)
        }
        func orFileDate(_ url: URL) -> (Date, Date) {
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date(timeIntervalSince1970: 0)
            return (first ?? m, last ?? m)
        }
    }
}
