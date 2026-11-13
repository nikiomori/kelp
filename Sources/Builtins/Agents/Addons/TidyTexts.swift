import Core
import Foundation

extension AddonGroups {
    /// The instruction files Tidy Up takes: the project's own and Claude Code's memory of it, not the person's files
    /// for every project (~/.claude/CLAUDE.md), which other projects read too.
    static func tidied(_ items: [Addon]) -> [Addon] {
        items.filter { $0.kind == .instructions && ($0.source == .project || $0.name == "MEMORY.md") }
    }

    /// What an instruction file holds now, in tokens, when the chat shown read another amount at its start (a Tidy Up
    /// since, an edit): the chat keeps what it read until it restarts. nil: no chat, or the same.
    static func behind(_ addon: Addon) -> Int? {
        guard addon.kind == .instructions, addon.loaded == true, let then = addon.tokens, let now = addon.check?.tokens,
            abs(now - then) > max(50, then / 10)
        else { return nil }
        return now
    }

    /// What's wrong with an instruction file, as what it means for the person, the worst first.
    static func findings(_ check: InstructionCheck, name: String) -> [String] {
        var out: [String] = []
        let reader = name == "AGENTS.md" ? "Codex" : "Claude"
        if check.cut == 1 {
            out.append(String(localized: "\(reader) doesn’t read its last line"))
        } else if check.cut > 1 {
            out.append(String(localized: "\(reader) doesn’t read its last \(check.cut) lines"))
        } else if (check.share ?? 0) >= InstructionCheck.near {
            out.append(String(localized: "Almost full"))
        }
        let dead = check.dead.count
        if dead == 1 { out.append(String(localized: "Mentions a file that’s gone")) }
        if dead > 1 { out.append(String(localized: "Mentions \(dead) files that are gone")) }
        if check.missing == 1 { out.append(String(localized: "A memory in its list is missing")) }
        if check.missing > 1 { out.append(String(localized: "\(check.missing) memories in its list are missing")) }
        if check.unlisted == 1 { out.append(String(localized: "A memory Claude never sees")) }
        if check.unlisted > 1 { out.append(String(localized: "\(check.unlisted) memories Claude never sees")) }
        return out
    }

    /// Needs a Look's line under the instruction files: the worst finding with its file's name and how many more there
    /// are, and whether agents lose lines or soon will (`warn`: the warning colour).
    static func instructionsText(_ files: [Addon]) -> (detail: String, warn: Bool) {
        func losing(_ file: Addon) -> Bool {
            (file.check?.cut ?? 0) > 0 || (file.check?.share ?? 0) >= InstructionCheck.near
        }
        let ordered = files.filter(losing) + files.filter { !losing($0) }
        let all = ordered.flatMap { file in
            (file.check.map { findings($0, name: file.name) } ?? []).map { "\(file.name): \($0)" }
        }
        guard let first = all.first else { return ("", false) }
        let more = all.count - 1
        return (first + (more > 0 ? " · " + String(localized: "\(more) more") : ""), files.contains(where: losing))
    }
}
