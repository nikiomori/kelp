import Core
import Foundation

/// What a Claude Code chat loaded when it started, as its own transcript says in its first notes: the skills it
/// listed, the tools of its MCP servers, the servers that didn't start, the instruction files it read.
/// Limit: only the notes at the top (the first `head` bytes); a server that connects minutes later isn't seen.
public struct ClaudeLoaded: Sendable, Equatable {
    public struct Skill: Sendable, Equatable {
        public var name: String, about: String
        /// Its line in the listing, in characters: what every request carries of it.
        public var chars: Int
    }
    public struct File: Sendable, Equatable {
        public var path: String, type: String, chars: Int
    }

    public var skills: [Skill] = []
    /// Tool names by MCP server ("claude_ai_Gmail": ["get_thread", …]), from `mcp__<server>__<tool>`.
    public var tools: [String: [String]] = [:]
    /// Servers that didn't start, with why.
    public var failed: [String: String] = [:]
    /// Characters of the instructions each server adds to the system prompt.
    public var notes: [String: Int] = [:]
    public var files: [File] = []

    static let head = 4 << 20

    public static func read(transcript url: URL) -> ClaudeLoaded? { Data(head: head, of: url).map(read) }

    static func read(_ data: Data) -> ClaudeLoaded {
        var out = ClaudeLoaded()
        let mark = Data(#""attachment""#.utf8)
        for line in JSONL.lines(data) where line.range(of: mark) != nil {
            guard let note = JSONL.object(line)?["attachment"] as? [String: Any] else { continue }
            out.add(note)
        }
        return out
    }

    private mutating func add(_ note: [String: Any]) {
        let names = note["addedNames"] as? [String] ?? []
        switch note["type"] as? String {
        case "skill_listing":
            // "- name: what it does", one a line; a later listing (after a compaction) repeats the first.
            guard skills.isEmpty || note["isInitial"] as? Bool == true else { return }
            skills = (note["content"] as? String ?? "").split(separator: "\n").compactMap(Self.skill)
        case "deferred_tools_delta":
            for name in names {
                let parts = name.components(separatedBy: "__")
                guard parts.count >= 3, parts[0] == "mcp" else { continue }
                tools[parts[1], default: []].append(parts[2...].joined(separator: "__"))
            }
            for server in note["failedMcpServers"] as? [[String: Any]] ?? [] {
                guard let name = server["name"] as? String else { continue }
                failed[name] = server["error"] as? String ?? server["errorCode"] as? String ?? ""
            }
        case "mcp_instructions_delta":
            let blocks = note["addedBlocks"] as? [String] ?? []
            for (name, block) in zip(names, blocks) { notes[name] = block.count }
        case "instructions":
            for file in note["files"] as? [[String: Any]] ?? [] {
                guard let path = file["path"] as? String, !files.contains(where: { $0.path == path }) else { continue }
                files.append(
                    File(
                        path: path, type: file["type"] as? String ?? "", chars: (file["content"] as? String)?.count ?? 0
                    ))
            }
        default: break
        }
    }

    /// "- plugin:name: what it does" → the name up to the colon a space follows.
    static func skill(_ line: Substring) -> Skill? {
        guard line.hasPrefix("- ") else { return nil }
        let text = line.dropFirst(2)
        guard let colon = text.range(of: ": ") else {
            return Skill(
                name: text.trimmingCharacters(in: CharacterSet(charactersIn: ": ")), about: "", chars: line.count)
        }
        return Skill(
            name: String(text[..<colon.lowerBound]), about: String(text[colon.upperBound...]), chars: line.count)
    }

    /// Characters as tokens, as `ClaudeContext` measured them.
    public static func tokens(_ chars: Int) -> Int { Int((Double(chars) / ClaudeContext.charsPerToken).rounded()) }
}
