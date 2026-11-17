import Foundation
import os

/// The names of the skills built into Claude Code. Kelp learns them from the "Built-in" rows of the Skills table that
/// /context prints, each time it reads such a print. A chat's record lists built-in skills and deleted skills alike, so
/// these names tell a built-in skill from one of the person's that was deleted after the chat started. The names are
/// nil until Kelp has read a print.
public enum ClaudeBuiltIns {
    private static let known = OSAllocatedUnfairLock<Set<String>?>(initialState: nil)

    public static var names: Set<String>? { known.withLock { $0 } }

    public static func learn(_ printed: String) {
        guard let found = read(printed) else { return }
        known.withLock { $0 = found }
    }

    /// Returns the built-in names, or nil when the print has no Skills table.
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
