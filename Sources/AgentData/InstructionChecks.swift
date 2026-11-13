import Core
import Foundation

/// What an instruction file says against what's on disk, without a model: its size against what its agents read of it,
/// the paths it names that are gone, and for Claude Code's memory index, its lines against the memory files.
public enum InstructionChecks {
    /// Claude Code reads the first 200 lines or 25 000 bytes of MEMORY.md, whichever comes first.
    public static let memoryLines = 200, memoryBytes = 25_000
    /// Codex stops adding AGENTS.md files once they reach 32 KiB together.
    static let codexBytes = 32_768
    /// What Anthropic advises for a CLAUDE.md: longer, and agents follow it less.
    static let advisedLines = 200
    /// At most this many dead paths are named: the rest only count against the agent's time, not the panel's.
    static let mostDead = 100

    /// `cwd`: the project's folder, where the paths it names are looked for. nil when the file can't be read.
    public static func check(_ path: String, cwd: String) -> InstructionCheck? {
        guard let text = text(path) else { return nil }
        let name = (path as NSString).lastPathComponent
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let count = text.hasSuffix("\n") ? lines.count - 1 : lines.count
        var check = InstructionCheck(lines: count, bytes: text.utf8.count)
        let seen = name == "MEMORY.md" ? String(decoding: Data(text.utf8).prefix(memoryBytes), as: UTF8.self) : text
        check.tokens = ClaudeLoaded.tokens(seen.count)
        switch name {
        case "MEMORY.md":
            (check.maxLines, check.maxBytes) = (memoryLines, memoryBytes)
            check.cut = count - read(lines, maxLines: memoryLines, maxBytes: memoryBytes)
            let memories = memoryFiles(beside: path)
            let named = indexed(text)
            check.missing = named.subtracting(memories.map(\.name)).count
            check.unlisted = memories.filter { !named.contains($0.name) }.count
            check.dead = dead(in: [text] + memories.map(\.text), cwd: cwd)
        case "AGENTS.md":
            (check.maxLines, check.maxBytes) = (advisedLines, codexBytes)
            check.cut = count - read(lines, maxLines: nil, maxBytes: codexBytes)
            check.dead = dead(in: [text], cwd: cwd)
        default:
            check.maxLines = advisedLines
            check.dead = dead(in: [text], cwd: cwd)
        }
        return check
    }

    /// How many of its lines an agent that stops at `maxLines` or `maxBytes` reads.
    static func read(_ lines: [Substring], maxLines: Int?, maxBytes: Int) -> Int {
        var bytes = 0
        for (index, line) in lines.enumerated() {
            if let maxLines, index >= maxLines { return index }
            bytes += line.utf8.count + 1
            if bytes > maxBytes { return index }
        }
        return lines.count
    }

    /// The memory files a MEMORY.md indexes: the Markdown files beside it (archive/ and the index itself left out).
    static func memoryFiles(beside index: String) -> [(name: String, text: String)] {
        let folder = (index as NSString).deletingLastPathComponent
        // Its files only, not archive/'s: subpaths names those with a "/".
        let names = FileManager.default.subpaths(atPath: folder) ?? []
        return names.filter { $0.hasSuffix(".md") && $0 != "MEMORY.md" && !$0.contains("/") }.sorted().compactMap {
            name in text(folder + "/" + name).map { (name, $0) }
        }
    }

    private static func text(_ path: String) -> String? {
        FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The memory files an index's links name: `[Title](file.md)`.
    static func indexed(_ text: String) -> Set<String> {
        Set(text.matches(of: /\]\(([^)\/\s]+\.md)\)/).map { String($0.1) })
    }

    /// Paths the texts name that aren't there. Only a path whose first folder is one of the project's counts: a word
    /// like "and/or.md" or a path of some other machine isn't the project's, and isn't a lead.
    static func dead(in texts: [String], cwd: String) -> [String] {
        let root = URL(fileURLWithPath: cwd)
        let manager = FileManager.default
        var folders: [String: Bool] = [:], seen = Set<String>(), out: [String] = []
        let pattern = pathPattern
        for text in texts {
            for match in text.matches(of: pattern) {
                let path = String(match.1)
                guard seen.insert(path).inserted, let first = path.split(separator: "/").first.map(String.init),
                    first != ".", first != ".."
                else { continue }
                if folders[first] == nil {
                    var isFolder: ObjCBool = false
                    let folder = root.appendingPathComponent(first).path
                    folders[first] = manager.fileExists(atPath: folder, isDirectory: &isFolder) && isFolder.boolValue
                }
                guard folders[first] == true, !manager.fileExists(atPath: root.appendingPathComponent(path).path)
                else { continue }
                out.append(path)
                if out.count == mostDead { return out }
            }
        }
        return out
    }

    /// A relative path with a folder and an extension ("Sources/Core/Paths.swift"), not part of a longer one: an
    /// address ("claude.ai/artifact/…") or a home path ("~/.kelp/x.json") starts after a "/" or a "." and doesn't count.
    static var pathPattern: Regex<(Substring, Substring)> {
        #/
            (?:^|[^\w\/~.$@-])
            ((?:[A-Za-z0-9_+-][A-Za-z0-9_.+-]*\/)+
             [A-Za-z0-9_+-][A-Za-z0-9_.+-]*\.[A-Za-z][A-Za-z0-9]{0,5})
            (?![\w\/])
        /#.anchorsMatchLineEndings()
    }
}
