import Foundation

/// What an agent is doing with a task, worked out from its chats (never stored): the most urgent of them.
public enum TaskWork: Int, Comparable, Sendable {
    /// No chat, or none that's on.
    case none
    /// Its chats are done or stopped: the work waits for the person's look.
    case review
    /// A chat works (or sleeps, paused, in the middle of it).
    case working
    /// A chat failed.
    case failed
    /// A chat asks the person something.
    case asks

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// The work of a task whose chats are `chats` (missing ones are gone and count for nothing).
    public static func of(_ chats: [Session]) -> TaskWork {
        chats.map { chat -> TaskWork in
            switch chat.status {
            case .waiting: .asks
            case .error: .failed
            case .working, .paused: .working
            case .done, .idle, .exited: .review
            }
        }.max() ?? .none
    }
}

/// One task as the lists show it: the line, its page and project, and the work of its chats.
public struct TaskRow: Equatable, Sendable {
    public var task: TaskLine, page: TaskPage, repo: String
    public var work: TaskWork
    public var id: String { "\(page.path)#\(task.id ?? String(task.line))" }
    /// The section the line is under, or the page when it's not the project's list.
    public var place: String {
        page.isList == true
            ? (task.section ?? page.title) : [page.title, task.section].compactMap { $0 }.joined(separator: " › ")
    }
    /// The `#words` in the line, as tags.
    public var tags: [String] {
        task.title.matches(of: #/(?:^|\s)#([\p{L}\p{N}_-]+)/#).map { String($0.output.1).lowercased() }
    }
    /// True while the person's turn is up: an agent asks, a proposal waits to be taken, or the work waits for a look.
    public var waitsForYou: Bool { task.state == .open && (task.proposed == true || work == .asks || work == .review) }
}

/// The lists of the Tasks tab and the panel's Tasks source: which rows each holds, in what groups.
public enum TaskSource: Hashable, Sendable {
    /// Lines under the first heading of a project's list.
    case inbox
    /// Lines an agent works on, or that wait for the person.
    case now
    /// Lines whose turn is the person's.
    case waiting
    /// Every open line.
    case all
    /// Done and cancelled lines, by day.
    case journal
    case project(String)
    case tag(String)

    /// Whether `row` belongs to the list.
    public func holds(_ row: TaskRow) -> Bool {
        // The lists show tasks; a step set in under one shows only once its turn comes (now, waiting, journal).
        let open = row.task.state == .open, task = open && row.task.depth == 0
        switch self {
        case .inbox: return task && row.page.isList == true && row.task.section == row.page.inbox
        case .now: return open && (row.work != .none || row.waitsForYou)
        case .waiting: return row.waitsForYou
        case .all: return task
        case .journal: return !open
        case .project(let repo): return task && row.repo == repo
        case .tag(let tag): return task && row.tags.contains(tag)
        }
    }
}

public enum TaskViews {
    /// The rows of `pages` (by project) with the work of their chats, as `session` finds them.
    public static func rows(_ pages: [(repo: String, pages: [TaskPage])], session: (String) -> Session?) -> [TaskRow] {
        pages.flatMap { repo, pages in
            pages.flatMap { page in
                page.tasks.map { task in
                    TaskRow(
                        task: task, page: page, repo: repo, work: .of((task.chats ?? []).compactMap(session)))
                }
            }
        }
    }

    /// The rows of `source` whose words hold `find` (a `#word` asks for that tag), in groups with their titles.
    /// `Now` groups by whose turn it is; the journal by day (as the Artifacts panel groups pages); the rest by page.
    public static func sections(
        _ rows: [TaskRow], _ source: TaskSource, find: String = "", projectName: (String) -> String = { $0 },
        now: Date = Date(), calendar: Calendar = .current, day: (Double) -> String
    ) -> [(title: String, rows: [TaskRow])] {
        let words = find.split(separator: " ")
        let tags = words.filter { $0.hasPrefix("#") }.map { $0.dropFirst().lowercased() }
        let text = words.filter { !$0.hasPrefix("#") }.joined(separator: " ")
        let shown = rows.filter { row in
            source.holds(row) && tags.allSatisfy(row.tags.contains)
                && (text.isEmpty
                    || "\(row.task.title) \(row.page.title) \(projectName(row.repo))"
                        .localizedCaseInsensitiveContains(text))
        }
        switch source {
        case .now:
            let asks = shown.filter(\.waitsForYou), going = shown.filter { !$0.waitsForYou }
            return [(String(localized: "Waiting for You"), asks), (String(localized: "Working"), going)]
                .filter { !$0.rows.isEmpty }
        case .journal:
            var out: [(title: String, rows: [TaskRow])] = []
            // A box ticked on the page itself keeps no time of its own: the page's last save stands for it.
            let when = { (row: TaskRow) in row.task.at ?? row.page.modified ?? 0 }
            for row in shown.sorted(by: { when($0) > when($1) }) {
                let title = day(when(row))
                if out.last?.title == title { out[out.count - 1].rows.append(row) } else { out.append((title, [row])) }
            }
            return out
        default:
            var out: [(title: String, rows: [TaskRow])] = []
            for row in shown {
                let title = "\(projectName(row.repo)) › \(row.place)"
                if let at = out.firstIndex(where: { $0.title == title }) {
                    out[at].rows.append(row)
                } else {
                    out.append((title, [row]))
                }
            }
            return out
        }
    }

    /// How many rows each of `sources` holds.
    public static func counts(_ rows: [TaskRow], _ sources: [TaskSource]) -> [TaskSource: Int] {
        Dictionary(uniqueKeysWithValues: sources.map { s in (s, rows.count(where: s.holds)) })
    }

    /// The tags in use on open lines, most used first.
    public static func tags(_ rows: [TaskRow]) -> [String] {
        var counts: [String: Int] = [:]
        for row in rows where row.task.state == .open { for t in row.tags { counts[t, default: 0] += 1 } }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }
}

extension TaskRow {
    /// The word beside a task's mark: what the person would want to know of the work (`chat` its liveliest chat).
    public func word(_ chat: Session?) -> String {
        if task.proposed == true { return String(localized: "Proposed") }
        switch work {
        case .asks: return String(localized: "Asks you")
        case .failed: return String(localized: "Failed")
        case .working: return chat?.status == .paused ? String(localized: "Paused") : String(localized: "Working")
        case .review: return task.state == .open ? String(localized: "To Review") : ""
        case .none: return ""
        }
    }

    /// The file of the page the task grew into, if it did.
    public var grownPage: String? {
        task.page.map {
            URL(fileURLWithPath: page.path).deletingLastPathComponent().appendingPathComponent($0)
                .standardizedFileURL.path
        }
    }

    /// The page that shows the task: the one it grew into, or the one it is on.
    public var pageFile: String { grownPage ?? page.path }
}

extension TaskViews {
    /// The task a chat (`session`) was started for, among its project's `pages`.
    public static func task(of session: String, in pages: [TaskPage]) -> TaskLine? {
        pages.lazy.flatMap(\.tasks).first { $0.chats?.contains(session) == true }
    }
}

extension TaskListNames {
    /// The list's title and first heading when a first task makes it, in the window's language.
    public static var localized: TaskListNames {
        TaskListNames(title: String(localized: "Tasks"), inbox: String(localized: "Inbox"))
    }
}
