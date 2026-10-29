import Foundation
import Core

/// What fills a Claude Code conversation's context (session.contextParts), read from its transcript since the last
/// compaction. Parts are counted at 4 characters a token, then scaled so that base + parts make what the last reply
/// counted (`used`): their shares are estimates, the total is exact.
/// Limit: thinking isn't counted (Claude Code drops it from later requests); an image counts as 1,600 tokens.
public enum ClaudeContext {
    public typealias Parts = SessionContextParts.Parts
    typealias Kind = SessionContextParts.Kind

    public static func parts(_ data: Data, used: Int) -> Parts? {
        let lines = JSONL.lines(data)
        guard used > 0, let first = base(lines) else { return nil }
        let start = lines.lastIndex { $0.range(of: Data("compact_boundary".utf8)) != nil && JSONL.object($0)?["subtype"] as? String == "compact_boundary" }
        var t = Tally()
        for line in lines[(start.map { $0 + 1 } ?? 0)...] { t.add(line) }
        let base = min(first, used), total = t.chars.values.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.chars } }
        guard total > 0 else { return Parts(base: base, parts: []) }
        let scale = Double(used - base) / Double(total)
        let parts = Kind.allCases.compactMap { kind -> SessionContextParts.Part? in
            guard let items = t.chars[kind], !items.isEmpty else { return nil }
            let sorted = items.map { SessionContextParts.Item(label: $0.key, tokens: Int(Double($0.value.chars) * scale), count: $0.value.count) }
                .sorted { $0.tokens > $1.tokens }
            return .init(kind: kind, tokens: sorted.reduce(0) { $0 + $1.tokens }, top: Array(sorted.prefix(3)), more: max(0, sorted.count - 3))
        }
        return Parts(base: base, parts: parts)
    }

    /// The first request: system prompt, tools, CLAUDE.md, skills, and what you typed first (taken off again).
    static func base(_ lines: [Data]) -> Int? {
        var typed = 0
        for line in lines {
            guard let o = JSONL.object(line), o["isSidechain"] as? Bool != true, let m = o["message"] as? [String: Any] else { continue }
            if o["type"] as? String == "user" { typed += text(m["content"]); continue }
            guard o["type"] as? String == "assistant", let u = m["usage"] as? [String: Any] else { continue }
            let input = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].reduce(0) { $0 + ((u[$1] as? Int) ?? 0) }
            if input > 0 { return max(0, input - typed / 4) }
        }
        return nil
    }

    /// Characters by part and label ("payment.ts", "npm test", "replies"), with how many times each came.
    struct Tally {
        var chars: [Kind: [String: (chars: Int, count: Int)]] = [:]
        private var tools: [String: (name: String, input: [String: Any])] = [:]

        mutating func count(_ kind: Kind, _ label: String, _ n: Int, times: Int = 1) {
            let old = chars[kind]?[label] ?? (0, 0)
            chars[kind, default: [:]][label] = (old.chars + n, old.count + times)
        }

        mutating func add(_ line: Data) {
            guard let o = JSONL.object(line), o["isSidechain"] as? Bool != true else { return }
            if o["type"] as? String == "attachment" {   // Claude Code's own notes: skills, CLAUDE.md, hook output
                let n = (o["rendered"] as? [[String: Any]] ?? []).reduce(0) { $0 + (($1["content"] as? String)?.count ?? 0) }
                if n > 0 { count(.conversation, "notes", n) }
                return
            }
            guard let m = o["message"] as? [String: Any] else { return }
            let blocks = m["content"] as? [[String: Any]] ?? []
            switch o["type"] as? String {
            case "assistant":
                for b in blocks {
                    if b["type"] as? String == "text" { count(.conversation, "replies", (b["text"] as? String)?.count ?? 0, times: 0) }
                    guard b["type"] as? String == "tool_use", let id = b["id"] as? String, let name = b["name"] as? String else { continue }
                    let input = b["input"] as? [String: Any] ?? [:]
                    tools[id] = (name, input)
                    count(.conversation, "replies", String(describing: input).count, times: 0)
                }
            case "user" where o["isCompactSummary"] as? Bool == true:
                count(.summary, "summary", text(m["content"]))
            case "user" where o["isMeta"] as? Bool == true:
                count(.conversation, "notes", text(m["content"]))
            case "user":
                let typed = text(m["content"])
                if typed > 0 { count(.conversation, "messages", typed) }
                for b in blocks where b["type"] as? String == "tool_result" {
                    let n = Self.size(b["content"])
                    guard let id = b["tool_use_id"] as? String, let (name, input) = tools[id] else { count(.commands, "?", n); continue }
                    switch name {
                    case "Read": count(.files, ((input["file_path"] as? String ?? "?") as NSString).lastPathComponent, n)
                    case "Bash": count(.commands, Self.command(input["command"] as? String ?? ""), n)
                    default: count(.commands, name.components(separatedBy: "__").last ?? name, n)
                    }
                }
            default: break
            }
        }

        /// A tool result's characters: its text, an image as 6,400 (≈ 1,600 tokens).
        static func size(_ content: Any?) -> Int {
            if let s = content as? String { return s.count }
            return (content as? [[String: Any]] ?? []).reduce(0) { n, b in
                n + (b["type"] as? String == "image" ? 6400 : (b["text"] as? String)?.count ?? 0)
            }
        }

        /// "cd app && npm test -- --watch=false" → "npm test": a command by its program and first word.
        static func command(_ c: String) -> String { AgentCommand.short(c).split(separator: " ").prefix(2).joined(separator: " ") }
    }

    /// What a message says in text: its string, or its text blocks (tool results aren't text).
    static func text(_ content: Any?) -> Int {
        if let s = content as? String { return s.count }
        return (content as? [[String: Any]] ?? []).reduce(0) { $0 + ($1["type"] as? String == "text" ? ($1["text"] as? String)?.count ?? 0 : 0) }
    }
}
