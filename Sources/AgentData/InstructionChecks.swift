import Core
import Foundation

/// Checks an instruction file against what is on disk, without a model. It compares the file's size with how much of
/// it the agents read and finds the paths it names that are gone. For Claude Code's memory index, it also compares the
/// index's lines with the memory files.
public enum InstructionChecks {
    /// Claude Code reads the first 200 lines or 25 000 bytes of MEMORY.md, whichever comes first.
    public static let memoryLines = 200, memoryBytes = 25_000
    /// Codex stops adding AGENTS.md files once they reach 32 KiB together.
    static let codexBytes = 32_768
    /// The most lines Anthropic advises for a CLAUDE.md, because agents follow a longer file less well.
    static let advisedLines = 200
    /// The check stops after naming this many dead paths. Any more still cost the agent time, but the panel doesn't
    /// spend time finding them.
    static let mostDead = 100

    /// Checks the file at `path`. `cwd` is the project's folder, where the paths the file names are looked for.
    /// Returns nil when the file can't be read.
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

    /// Returns how many of the lines an agent reads when it stops at `maxLines` or `maxBytes`.
    static func read(_ lines: [Substring], maxLines: Int?, maxBytes: Int) -> Int {
        var bytes = 0
        for (index, line) in lines.enumerated() {
            if let maxLines, index >= maxLines { return index }
            bytes += line.utf8.count + 1
            if bytes > maxBytes { return index }
        }
        return lines.count
    }

    /// Returns the memory files that a MEMORY.md indexes: the Markdown files beside it, except archive/ and the index.
    static func memoryFiles(beside index: String) -> [(name: String, text: String)] {
        let folder = (index as NSString).deletingLastPathComponent
        // Only the folder's own files count, not those in archive/. `subpaths` names those with a "/".
        let names = FileManager.default.subpaths(atPath: folder) ?? []
        return names.filter { $0.hasSuffix(".md") && $0 != "MEMORY.md" && !$0.contains("/") }.sorted().compactMap {
            name in text(folder + "/" + name).map { (name, $0) }
        }
    }

    private static func text(_ path: String) -> String? {
        FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Returns the memory files that the index's links name, as in `[Title](file.md)`.
    static func indexed(_ text: String) -> Set<String> {
        Set(text.matches(of: /\]\(([^)\/\s]+\.md)\)/).map { String($0.1) })
    }

    /// Returns the paths the texts name that don't exist. A path counts only when its first folder is one of the
    /// project's folders, because a word like "and/or.md" or a path on another machine isn't a lead.
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

    /// Matches a relative path with a folder and an extension ("Sources/Core/Paths.swift") that isn't part of a longer
    /// one. A match can't start right after a "/" or a ".", so the inner part of an address ("claude.ai/artifact/…") or
    /// of a home path ("~/.kelp/x.json") doesn't count.
    static var pathPattern: Regex<(Substring, Substring)> {
        #/
            (?:^|[^\w\/~.$@-])
            ((?:[A-Za-z0-9_+-][A-Za-z0-9_.+-]*\/)+
             [A-Za-z0-9_+-][A-Za-z0-9_.+-]*\.[A-Za-z][A-Za-z0-9]{0,5})
            (?![\w\/])
        /#.anchorsMatchLineEndings()
    }
}
