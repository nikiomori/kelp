import Foundation

/// What the person decided about a task: still to do, done, or given up (`- [ ]`, `- [x]`, `- [-]`). What an agent is
/// doing with it is never stored: it is worked out from the task's chats.
public enum TaskState: String, Codable, Sendable, CaseIterable {
    case open, done, cancelled
}

/// One task: a `- [ ]` line on a page of Kelp's (`.kelp/artifacts`). Kelp's own facts about it ride at the end of the
/// line in a comment the page doesn't show, `<!-- k:7f3a chats:<session>,… -->`, so they move with the line when it is
/// cut and pasted elsewhere. A line gets an id only once something needs one (a chat, a change from the list); a line
/// written by hand is a task all the same.
public struct TaskLine: Codable, Equatable, Sendable {
    public var id: String?
    /// The line's words, without its box and Kelp's comment.
    public var text: String
    public var state: TaskState
    /// The 1-based line in its page, as read.
    public var line: Int
    /// How far in the line is set: 0 for a task of its own, 1 for a step under one, and so on.
    public var depth: Int
    /// The heading the line is under (`## Inbox`), without its `#`s. nil before the first heading under the title.
    public var section: String?
    /// True for a line an agent wrote that the person hasn't taken yet. `by` is that agent's session, `at` when.
    public var proposed: Bool?
    public var by: String?
    public var at: Double?
    /// The chats started for the task, oldest first.
    public var chats: [String]?
    /// The issue the task came from (GitHub, Linear, Jira), by its link.
    public var issue: String?

    public init(
        id: String? = nil, text: String, state: TaskState = .open, line: Int = 0, depth: Int = 0,
        section: String? = nil, proposed: Bool? = nil, by: String? = nil, at: Double? = nil, chats: [String]? = nil,
        issue: String? = nil
    ) {
        self.id = id
        self.text = text
        self.state = state
        self.line = line
        self.depth = depth
        self.section = section
        self.proposed = proposed
        self.by = by
        self.at = at
        self.chats = chats
        self.issue = issue
    }

    /// The words without Markdown's link syntax: `[Search](../search/doc.md)` reads "Search".
    public var title: String {
        text.replacing(#/\[([^\]]*)\]\([^)]*\)/#) { String($0.output.1) }
    }

    /// How the issue is named where it lives: `#212` on GitHub, `LIN-42` on Linear, `KEL-7` on Jira.
    public var issueRef: String? {
        guard let issue else { return nil }
        if let n = issue.firstMatch(of: #/\/(?:issues|pull)\/(\d+)/#) { return "#" + n.output.1 }
        if let key = issue.firstMatch(of: #/\/([A-Z][A-Z0-9]+-\d+)/#) { return String(key.output.1) }
        return issue
    }

    /// The page the line links to (a task that grew into a page of its own), as written: relative to the line's page.
    public var page: String? {
        text.firstMatch(of: #/\]\(([^)\s]+\.md)\)/#).map { String($0.output.1) }
    }
}

/// Which task a change is for: by its id, or, for a line with none yet, by its line and words (so a line that moved
/// since it was read isn't changed by mistake).
public struct TaskRef: Codable, Equatable, Sendable {
    public var id: String?, line: Int?, text: String?
    public init(id: String? = nil, line: Int? = nil, text: String? = nil) {
        self.id = id
        self.line = line
        self.text = text
    }
    public init(_ task: TaskLine) { self.init(id: task.id, line: task.line, text: task.text) }
}

/// Reading and writing task lines in a page's Markdown. Pure: the daemon, the Tasks tab and the CLI all go through
/// these, so a line reads and is written the same way everywhere.
public enum TaskLines {
    /// Every task line of `text`, in order.
    public static func parse(_ text: String) -> [TaskLine] {
        var out: [TaskLine] = [], section: String?
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            if let heading = raw.firstMatch(of: #/^(#{1,6})\s+(.*?)\s*#*\s*$/#) {
                if heading.output.1.count >= 2 { section = String(heading.output.2) }
                continue
            }
            guard var task = line(raw) else { continue }
            task.line = i + 1
            task.section = section
            out.append(task)
        }
        return out
    }

    /// What "done" means for a task's page: the words after its **Done when:** line, in any of Kelp's languages, as
    /// the person wrote them. nil when the line is missing or empty.
    public static func goal(_ text: String) -> String? {
        for raw in text.components(separatedBy: "\n") {
            guard let m = raw.firstMatch(of: #/^\s*\*\*(.+?):\*\*\s*(.*?)\s*$/#),
                goalLabels.contains(String(m.output.1))
            else { continue }
            return m.output.2.isEmpty ? nil : String(m.output.2)
        }
        return nil
    }
    /// "Done when" in each language Kelp speaks, as a grown page's line names it.
    public static let goalLabels: Set<String> = [
        "Done when", "Готово, когда", "Fertig, wenn", "Listo cuando", "完了条件", "完成标准"
    ]

    /// The page's headings under its title (`##` and deeper), in order.
    public static func sections(_ text: String) -> [String] {
        text.components(separatedBy: "\n").compactMap { raw in
            raw.firstMatch(of: #/^#{2,6}\s+(.*?)\s*#*\s*$/#).map { String($0.output.1) }
        }
    }

    /// The task one line holds, or nil for any other line.
    public static func line(_ raw: String) -> TaskLine? {
        guard let m = raw.firstMatch(of: #/^(\s*)(?:[-*+]|\d+[.)])\s+\[([ xX-])\]\s?(.*)$/#) else { return nil }
        let state: TaskState = m.output.2 == " " ? .open : m.output.2 == "-" ? .cancelled : .done
        var words = String(m.output.3), facts: [Substring] = []
        if let comment = words.firstMatch(of: #/\s*<!--\s*(k:[^>]*?)\s*-->\s*$/#) {
            facts = comment.output.1.split(separator: " ")
            words.removeSubrange(comment.range)
        }
        let indent = m.output.1.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        var task = TaskLine(text: words.trimmingCharacters(in: .whitespaces), state: state, depth: indent / 2)
        for fact in facts {
            let parts = fact.split(separator: ":", maxSplits: 1).map(String.init)
            switch (parts.first, parts.count > 1 ? parts[1] : nil) {
            case ("k", let v?): task.id = v
            case ("proposed", nil): task.proposed = true
            case ("by", let v?): task.by = v
            case ("at", let v?): task.at = Double(v)
            case ("chats", let v?): task.chats = v.split(separator: ",").map(String.init)
            case ("issue", let v?): task.issue = v
            default: break
            }
        }
        return task
    }

    /// The line `task` is written as, at `depth` (two spaces a step).
    public static func written(_ task: TaskLine) -> String {
        let box = task.state == .open ? " " : task.state == .done ? "x" : "-"
        var facts: [String] = []
        if let id = task.id { facts.append("k:\(id)") }
        if task.proposed == true { facts.append("proposed") }
        if let by = task.by { facts.append("by:\(by)") }
        if let at = task.at { facts.append("at:\(Int(at))") }
        if let chats = task.chats, !chats.isEmpty { facts.append("chats:" + chats.joined(separator: ",")) }
        if let issue = task.issue { facts.append("issue:\(issue)") }
        let comment = facts.isEmpty || task.id == nil ? "" : " <!-- \(facts.joined(separator: " ")) -->"
        return String(repeating: "  ", count: task.depth) + "- [\(box)] " + task.text + comment
    }

    /// A new task id: four or more hex digits, not one of `taken`.
    public static func newId(taken: Set<String>) -> String {
        while true {
            let id = String(format: "%04x", UInt16.random(in: 0...UInt16.max))
            if !taken.contains(id) { return id }
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noTask(TaskRef)
        public var description: String {
            switch self {
            case .noTask(let ref):
                let which = ref.id.map { "k:\($0)" } ?? "at line \(ref.line ?? 0)"
                return "no task \(which) on the page (it moved or was deleted)"
            }
        }
    }

    /// The 0-based index of the line `ref` names among `lines`.
    public static func index(of ref: TaskRef, in lines: [String]) throws -> Int {
        if let id = ref.id, let at = lines.firstIndex(where: { line($0)?.id == id }) { return at }
        if let n = ref.line, lines.indices.contains(n - 1), let task = line(lines[n - 1]),
            ref.id == nil || task.id == nil, ref.text.map({ $0 == task.text }) ?? true
        {
            return n - 1
        }
        throw Failure.noTask(ref)
    }

    /// `text` with the task `ref` names changed by `change`, given an id if it had none. Returns the new text and the
    /// task as written.
    public static func change(
        _ text: String, _ ref: TaskRef, _ change: (inout TaskLine) -> Void
    ) throws -> (text: String, task: TaskLine) {
        var lines = text.components(separatedBy: "\n")
        let at = try index(of: ref, in: lines)
        guard var task = line(lines[at]) else { throw Failure.noTask(ref) }
        if task.id == nil { task.id = newId(taken: Set(parse(text).compactMap(\.id))) }
        change(&task)
        lines[at] = written(task)
        task.line = at + 1
        return (lines.joined(separator: "\n"), task)
    }

    /// `text` without the task `ref` names.
    public static func remove(_ text: String, _ ref: TaskRef) throws -> String {
        var lines = text.components(separatedBy: "\n")
        lines.remove(at: try index(of: ref, in: lines))
        return lines.joined(separator: "\n")
    }

    /// `text` with `task` added as the last line under the heading `section` (a `##` heading), or under the first
    /// `##` heading when `section` is nil. A heading that isn't there is added at the end. Returns the new text and the
    /// line the task went to (1-based).
    public static func add(_ task: TaskLine, under section: String?, to text: String, newSection: String)
        -> (text: String, line: Int)
    {
        var lines = text.components(separatedBy: "\n")
        let isHeading = { (s: String) in s.firstMatch(of: #/^#{2,6}\s/#) != nil }
        let name = { (s: String) in s.firstMatch(of: #/^#{2,6}\s+(.*?)\s*#*\s*$/#).map { String($0.output.1) } }
        var start = section.flatMap { wanted in lines.firstIndex { isHeading($0) && name($0) == wanted } }
        if section == nil { start = lines.firstIndex(where: isHeading) }
        guard let start else {
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            lines += ["", "## " + (section ?? newSection), written(task), ""]
            return (lines.joined(separator: "\n"), lines.count - 1)
        }
        let end = lines[(start + 1)...].firstIndex(where: { $0.firstMatch(of: #/^#{1,6}\s/#) != nil }) ?? lines.count
        var last = start
        for i in (start + 1)..<end where !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { last = i }
        let at = last + 1
        lines.insert(written(task), at: at)
        if last == start, at + 1 < lines.count, !lines[at + 1].trimmingCharacters(in: .whitespaces).isEmpty,
            lines[at + 1].firstMatch(of: #/^#{1,6}\s/#) != nil
        {
            lines.insert("", at: at + 1)   // a blank line before the next heading
        }
        return (lines.joined(separator: "\n"), at + 1)
    }
}
