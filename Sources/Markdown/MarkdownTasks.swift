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
