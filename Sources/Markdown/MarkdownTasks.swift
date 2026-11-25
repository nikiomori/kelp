import Foundation

/// A task list's boxes ticked from the page: the source changes at the task's line.
public enum MarkdownTasks {
    /// `text` with the task at `line` (1-based) ticked or not; unchanged when that line holds no task.
    public static func set(_ text: String, line: Int, done: Bool) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line - 1),
            let box = lines[line - 1].firstMatch(of: #/^(\s*(?:[-*+]|\d+[.)])\s+)\[[ xX]\]/#)
        else { return text }
        lines[line - 1].replaceSubrange(box.range, with: box.output.1 + (done ? "[x]" : "[ ]"))
        return lines.joined(separator: "\n")
    }
}

/// A paragraph or a heading typed over on the page: its lines in the Markdown become the words typed, a heading keeping
/// its `#`s. Only plain ones: one with links, emphasis, code or HTML in it is changed in the source, where those show.
public enum MarkdownRetext {
    /// `text` with the block that starts at `line` (and ends before `end`, or at the next blank line) holding `words`;
    /// nil when that block isn't a plain paragraph or heading.
    public static func set(_ text: String, line: Int, end: Int?, words: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line - 1) else { return nil }
        var last = min((end ?? Int.max) - 2, lines.count - 1)
        if let blank = lines[(line - 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            last = min(last, blank - 1)
        }
        if !heading(lines[line - 1]).isEmpty { last = line - 1 }   // a heading is one line
        guard last >= line - 1 else { return nil }
        let block = lines[(line - 1)...last], first = block.first ?? "", title = heading(first)
        let marks = #/[*_`\[\]<>|]/#, starts = #/^\s*(?:#|[-+>]|\d+[.)])\s/#
        guard first.dropFirst(title.count).firstMatch(of: marks) == nil,
            !title.isEmpty || first.firstMatch(of: starts) == nil,
            block.dropFirst().allSatisfy({ $0.firstMatch(of: marks) == nil && $0.firstMatch(of: starts) == nil })
        else { return nil }
        let typed = words.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return nil }
        lines.replaceSubrange((line - 1)...last, with: [title + typed])
        return lines.joined(separator: "\n")
    }

    private static func heading(_ line: String) -> String {
        line.firstMatch(of: #/^#{1,6}\s+/#).map { String($0.output) } ?? ""
    }
}
