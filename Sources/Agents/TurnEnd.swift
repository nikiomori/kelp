import Foundation
import Core

/// What Claude Code's Stop means: the turn ended, unless the agent goes on by itself. It waits for subagents or a
/// workflow, checks a /goal after each turn, or is woken when a command it started in the background ends (a
/// `<task-notification>` prompt).
public struct TurnEnd: Sendable {
    public enum Verdict: Equatable, Sendable { case done, working, goal(String), command(String) }

    /// Background shells running at an earlier Stop: one that outlives a turn is a server, not something awaited.
    private var seen: Set<String> = []
    public init() {}

    /// `tasks`: the Stop's `background_tasks`; `goal`: the transcript's last goal_status. Also returns the commands still
    /// running in the background, for the row.
    public mutating func stop(_ tasks: [JSONValue], goal: GoalStatus?) -> (Verdict, [String]) {
        let shells = tasks.filter { $0["type"]?.string == "shell" && ($0["status"]?.string ?? "running") == "running" }
        let running = shells.map { $0["command"]?.string ?? $0["description"]?.string ?? "" }
        let fresh = shells.filter { !seen.contains($0["id"]?.string ?? "") }.compactMap { $0["command"]?.string }
        seen = Set(shells.compactMap { $0["id"]?.string })
        if tasks.contains(where: { !["shell", "monitor"].contains($0["type"]?.string ?? "") }) { return (.working, running) }
        if let goal, !goal.met { return (.goal(goal.condition), running) }
        if let awaited = fresh.first(where: { !Self.looksLikeServer($0) }) { return (.command(awaited), running) }
        return (.done, running)
    }

    /// A command that runs until stopped (a dev server, a watcher, a log tail): the agent doesn't wait for it.
    /// Limit: a guess from the words; a server it misses holds the row "working" until the wait runs out.
    public static func looksLikeServer(_ command: String) -> Bool {
        command.range(of: #"(?i)\b(dev|serve|server|start|watch|preview)\b|compose up|tail -f|--follow|\blogs -f"#, options: .regularExpression) != nil
    }
}

/// A /goal's state as Claude Code writes it into its transcript (a `goal_status` attachment, after each check).
public struct GoalStatus: Equatable, Sendable {
    public var met: Bool, condition: String, id: String

    /// The last goal_status in a transcript's tail (JSON lines; the first may be cut).
    public static func last(in tail: String) -> GoalStatus? {
        for line in tail.split(separator: "\n").reversed() where line.contains("\"goal_status\"") {
            guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)), let a = v["attachment"],
                  a["type"]?.string == "goal_status" else { continue }
            return GoalStatus(met: a["met"]?.bool ?? false, condition: a["condition"]?.string ?? "", id: v["uuid"]?.string ?? String(line.hashValue))
        }
        return nil
    }

    /// The last 256 KB of a transcript: goal checks are near its end.
    public static func last(inFile path: String) -> GoalStatus? {
        guard let f = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? f.close() }
        let end = (try? f.seekToEnd()) ?? 0
        try? f.seek(toOffset: end > 262_144 ? end - 262_144 : 0)
        return (try? f.readToEnd()).flatMap { last(in: String(decoding: $0, as: UTF8.self)) }
    }
}
