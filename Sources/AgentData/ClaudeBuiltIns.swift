import Foundation
import os

/// The skills Claude Code brings itself, by name, learnt from what its /context prints (the Skills table's
/// "Built-in" rows) whenever Kelp reads one: they tell a skill of Claude Code's own from one of the person's that was
/// deleted after a chat started, which the chat's record lists alike. nil until one was read.
public enum ClaudeBuiltIns {
    private static let known = OSAllocatedUnfairLock<Set<String>?>(initialState: nil)

    public static var names: Set<String>? { known.withLock { $0 } }

    public static func learn(_ printed: String) {
        guard let found = read(printed) else { return }
        known.withLock { $0 = found }
    }

    /// nil when the print has no Skills table.
    static func read(_ printed: String) -> Set<String>? {
        var section = "", seen = false, names = Set<String>()
        for line in printed.split(separator: "\n") {
            if line.hasPrefix("#") {
                section = line.drop { $0 == "#" || $0 == " " }.trimmingCharacters(in: .whitespaces)
                continue
            }
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard section == "Skills", line.hasPrefix("|"), cells.count >= 3, !cells[0].hasPrefix("-") else { continue }
            seen = true
            if cells[1] == "Built-in" { names.insert(cells[0]) }
        }
        return seen ? names : nil
    }
}
