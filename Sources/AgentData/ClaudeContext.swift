import Core
import Foundation

/// What fills a Claude Code conversation's context (session.contextParts), read from its transcript since the last
/// compaction. Parts are counted in characters, then scaled so that base + parts make what the last reply counted
/// (`used`): their shares are estimates, the total is exact. Thinking stays in the context, so it's a line of the conversation.
public enum ClaudeContext {
    /// Measured on Opus 5.5 against what requests counted: 0.42 tokens a character, and an image is about 1,880 tokens.
    static let charsPerToken = 2.37, imageChars = 4456
    public typealias Parts = SessionContextParts.Parts
    typealias Kind = SessionContextParts.Kind

    /// A reply's writes say how long the cache lasts from it: an hour for a plan's main conversation, else five minutes.
    public static func cacheUntil(_ line: [String: Any], _ usage: [String: Any]) -> Date? {
        func wrote(_ kind: String) -> Bool { ((usage["cache_creation"] as? [String: Any])?[kind] as? Int ?? 0) > 0 }
        guard wrote("ephemeral_1h_input_tokens") || wrote("ephemeral_5m_input_tokens"),
            let at = JSONL.date(line["timestamp"])
        else { return nil }
        return at.addingTimeInterval(wrote("ephemeral_1h_input_tokens") ? 3600 : 300)
    }

    public static func parts(_ data: Data, used: Int) -> Parts? {
        let lines = JSONL.lines(data)
        guard used > 0, let first = base(lines) else { return nil }
        let start = lines.lastIndex {
            $0.range(of: Data("compact_boundary".utf8)) != nil
                && JSONL.object($0)?["subtype"] as? String == "compact_boundary"
        }
        var tally = Tally()
        for line in lines[(start.map { $0 + 1 } ?? 0)...] { tally.add(line) }
        let base = min(first, used), total = tally.chars.values.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.chars } }
        guard total > 0 else { return Parts(base: base, parts: []) }
        let scale = Double(used - base) / Double(total)
        let parts = Kind.allCases.compactMap { kind -> SessionContextParts.Part? in
            guard let items = tally.chars[kind], !items.isEmpty else { return nil }
            let sorted = items.map {
                SessionContextParts.Item(
                    label: $0.key, tokens: Int(Double($0.value.chars) * scale), count: $0.value.count)
            }
            .sorted { $0.tokens > $1.tokens }
            return .init(
                kind: kind, tokens: sorted.reduce(0) { $0 + $1.tokens }, top: Array(sorted.prefix(3)),
                more: max(0, sorted.count - 3))
        }
        return Parts(base: base, parts: parts)
    }

    /// What `claude -p /context` prints, read: its categories, the tools it defers, the autocompact buffer, and the
    /// memory files, skills and custom agents it lists. nil when there's no table of categories in it.
    public static func setup(_ printed: String) -> SessionContextParts.Setup? {
        let lists = ["Memory Files": "Memory files", "Skills": "Skills", "Custom Agents": "Custom agents"]
        var section = "", parts: [SessionContextParts.Setup.Group] = [], deferred: [SessionContextParts.Item] = [],
            buffer = 0
        var items: [String: [SessionContextParts.Item]] = [:]
        for line in printed.split(separator: "\n") {
            if line.hasPrefix("#") {
                section = line.drop { $0 == "#" || $0 == " " }.trimmingCharacters(in: .whitespaces)
                continue
            }
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard line.hasPrefix("|"), cells.count >= 2 else { continue }
            if section == "Estimated usage by category", let count = tokens(cells[1]) {
                switch cells[0] {
                case "Autocompact buffer": buffer = count
                case "Messages", "Free space": break   // the conversation is read from the transcript
                case let name where name.hasSuffix("(deferred)"): deferred.append(.init(label: name, tokens: count))
                case let name: parts.append(.init(label: name, tokens: count))
                }
            } else if let group = lists[section], cells.count >= 3, let count = tokens(cells[cells.count - 1]) {
                let label = section == "Memory Files" ? (cells[1] as NSString).lastPathComponent : cells[0]   // Type | Path | Tokens
                items[group, default: []].append(.init(label: label, tokens: count))
            }
        }
        guard !parts.isEmpty else { return nil }
        for index in parts.indices {
            guard let list = items[parts[index].label]?.sorted(by: { $0.tokens > $1.tokens }) else { continue }
            parts[index].top = Array(list.prefix(3))
            parts[index].more = max(0, list.count - 3)
        }
        return .init(parts: parts, deferred: deferred, buffer: buffer)
    }

    /// "2.5k" → 2500, "~300" → 300, "1m" → 1,000,000; nil for a header ("Tokens").
    static func tokens(_ cell: String) -> Int? {
        var number = cell.trimmingCharacters(in: CharacterSet(charactersIn: "~ ")).lowercased(), unit = 1.0
        if number.hasSuffix("k") {
            unit = 1e3
            number.removeLast()
        } else if number.hasSuffix("m") {
            unit = 1e6
            number.removeLast()
        }
        return Double(number).map { Int(($0 * unit).rounded()) }
    }

    /// The setup as /context counts it, and what else the session's first request held as one more part, "Other" (hook
    /// output, the environment, the names of the tools it defers…: /context leaves those out), so the parts make `base`,
    /// what that request really counted. Scaled down only when /context counts more: its fresh copy of the agent may have
    /// more skills or MCP servers than the session started with.
    public static func fit(_ setup: SessionContextParts.Setup, to base: Int) -> SessionContextParts.Setup {
        let sum = setup.parts.reduce(0) { $0 + $1.tokens }
        var out = setup
        guard sum > base else {
            if base > sum { out.parts.append(.init(label: "Other", tokens: base - sum)) }
            return out
        }
        let factor = Double(base) / Double(sum)
        for part in out.parts.indices {
            out.parts[part].tokens = Int(Double(out.parts[part].tokens) * factor)
            for item in out.parts[part].top.indices {
                out.parts[part].top[item].tokens = Int(Double(out.parts[part].top[item].tokens) * factor)
            }
        }
        return out
    }

    /// The first request: system prompt, tools, CLAUDE.md, skills, and what you typed first (taken off again).
    static func base(_ lines: [Data]) -> Int? {
        var typed = 0
        for line in lines {
            guard let object = JSONL.object(line), object["isSidechain"] as? Bool != true,
                let message = object["message"] as? [String: Any]
            else { continue }
            if object["type"] as? String == "user" {
                typed += text(message["content"])
                continue
            }
            guard object["type"] as? String == "assistant", let usage = message["usage"] as? [String: Any] else {
                continue
            }
            let input = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].reduce(0) {
                $0 + ((usage[$1] as? Int) ?? 0)
            }
            if input > 0 { return max(0, input - Int(Double(typed) / charsPerToken)) }
        }
        return nil
    }

    /// Characters by part and label ("payment.ts", "npm test", "replies"), with how many times each came.
    struct Tally {
        var chars: [Kind: [String: (chars: Int, count: Int)]] = [:]
        private var tools: [String: (name: String, input: [String: Any])] = [:]
        /// One reply is a line per block, each with the reply's whole usage.
        private var thought = Set<String>()
        /// Notes before the first reply (skills, CLAUDE.md, the tools it defers, hook output) went with the first
        /// request, or came back with the compaction: the base, counted there.
        private var replied = false

        mutating func count(_ kind: Kind, _ label: String, _ amount: Int, times: Int = 1) {
            let old = chars[kind]?[label] ?? (0, 0)
            chars[kind, default: [:]][label] = (old.chars + amount, old.count + times)
        }

        mutating func add(_ line: Data) {
            guard let object = JSONL.object(line), object["isSidechain"] as? Bool != true else { return }
            if object["type"] as? String == "attachment" {   // Claude Code's own notes: skills, CLAUDE.md, hook output
                guard replied else { return }
                let notes = (object["rendered"] as? [[String: Any]] ?? []).reduce(0) {
                    $0 + (($1["content"] as? String)?.count ?? 0)
                }
                if notes > 0 { count(.conversation, "notes", notes) }
                return
            }
            guard let message = object["message"] as? [String: Any] else { return }
            let blocks = message["content"] as? [[String: Any]] ?? []
            switch object["type"] as? String {
            case "assistant":
                replied = true
                if let id = message["id"] as? String, thought.insert(id).inserted,
                    let details = (message["usage"] as? [String: Any])?["output_tokens_details"] as? [String: Any],
                    let thinking = details["thinking_tokens"] as? Int, thinking > 0
                {
                    count(.conversation, "thinking", Int(Double(thinking) * ClaudeContext.charsPerToken), times: 0)
                }
                for block in blocks {
                    if block["type"] as? String == "text" {
                        count(.conversation, "replies", (block["text"] as? String)?.count ?? 0, times: 0)
                    }
                    guard block["type"] as? String == "tool_use", let id = block["id"] as? String,
                        let name = block["name"] as? String
                    else { continue }
                    let input = block["input"] as? [String: Any] ?? [:]
                    tools[id] = (name, input)
                    count(.conversation, "replies", String(describing: input).count, times: 0)
                }
            case "user" where object["isCompactSummary"] as? Bool == true:
                count(.summary, "summary", text(message["content"]))
            case "user" where object["isMeta"] as? Bool == true:
                count(.conversation, "notes", text(message["content"]))
            case "user":
                let typed = text(message["content"])
                if typed > 0 { count(.conversation, "messages", typed) }
                for block in blocks where block["type"] as? String == "tool_result" {
                    let size = Self.size(block["content"])
                    guard let id = block["tool_use_id"] as? String, let (name, input) = tools[id] else {
                        count(.commands, "?", size)
                        continue
                    }
                    switch name {
                    case "Read":
                        count(.files, ((input["file_path"] as? String ?? "?") as NSString).lastPathComponent, size)
                    case "Bash": count(.commands, Self.command(input["command"] as? String ?? ""), size)
                    default: count(.commands, name.components(separatedBy: "__").last ?? name, size)
                    }
                }
            default: break
            }
        }

        /// A tool result's characters: its text, an image as `imageChars`.
        static func size(_ content: Any?) -> Int {
            if let string = content as? String { return string.count }
            return (content as? [[String: Any]] ?? []).reduce(0) { sum, block in
                sum + (block["type"] as? String == "image" ? imageChars : (block["text"] as? String)?.count ?? 0)
            }
        }

        /// "cd app && npm test -- --watch=false" → "npm test": a command by its program and first word.
        static func command(_ line: String) -> String {
            AgentCommand.short(line).split(separator: " ").prefix(2).joined(separator: " ")
        }
    }

    /// What a message says in text: its string, or its text blocks (tool results aren't text).
    static func text(_ content: Any?) -> Int {
        if let string = content as? String { return string.count }
        return (content as? [[String: Any]] ?? []).reduce(0) {
            $0 + ($1["type"] as? String == "text" ? ($1["text"] as? String)?.count ?? 0 : 0)
        }
    }
}
