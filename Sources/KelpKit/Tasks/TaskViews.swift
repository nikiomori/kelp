import Core
import Foundation

/// What an agent is doing with a task, worked out from its chats (never stored): the most urgent of them.
package enum TaskWork: Int, Comparable, Sendable {
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

    package static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// The work of a task whose chats are `chats` (missing ones are gone and count for nothing).
    static func of(_ chats: [Session]) -> TaskWork {
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
package struct TaskRow: Equatable, Sendable {
    package var task: TaskLine, page: TaskPage, repo: String
    package var work: TaskWork
    package var id: String { "\(page.path)#\(task.id ?? String(task.line))" }
    /// The section the line is under, or the page when it's not the project's list.
    package var place: String {
        page.isList == true
            ? (task.section ?? page.title) : [page.title, task.section].compactMap { $0 }.joined(separator: " › ")
    }
    /// The `#words` in the line, as tags.
    var tags: [String] {
        task.title.matches(of: #/(?:^|\s)#([\p{L}\p{N}_-]+)/#).map { String($0.output.1).lowercased() }
    }
    /// True while the person's turn is up: an agent asks, a proposal waits to be taken, or the work waits for a look.
    var waitsForYou: Bool { task.state == .open && (task.proposed == true || work == .asks || work == .review) }
}

/// The lists of the Tasks tab and the panel's Tasks source: which rows each holds, in what groups.
package enum TaskSource: Hashable, Sendable {
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
    package func holds(_ row: TaskRow) -> Bool {
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

package enum TaskViews {
    /// The rows of `pages` (by project) with the work of their chats, as `session` finds them.
    package static func rows(_ pages: [(repo: String, pages: [TaskPage])], session: (String) -> Session?) -> [TaskRow] {
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
    package static func sections(
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
    package static func counts(_ rows: [TaskRow], _ sources: [TaskSource]) -> [TaskSource: Int] {
        Dictionary(uniqueKeysWithValues: sources.map { s in (s, rows.count(where: s.holds)) })
    }

    /// The tags in use on open lines, most used first.
    package static func tags(_ rows: [TaskRow]) -> [String] {
        var counts: [String: Int] = [:]
        for row in rows where row.task.state == .open { for t in row.tags { counts[t, default: 0] += 1 } }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }
}

/// The board's columns, as the Agents Overview's stages, with two before them for work no agent has started: an idea
/// (a line), and a plan (a line that grew into a page).
package enum TaskColumn: Int, CaseIterable, Sendable {
    case ideas, plan, working, review, pullRequest, done

    package var title: String {
        switch self {
        case .ideas: String(localized: "Ideas")
        case .plan: String(localized: "Plan")
        case .working: String(localized: "Working")
        case .review: String(localized: "To Review")
        case .pullRequest: String(localized: "In PR")
        case .done: String(localized: "Done")
        }
    }
}

extension TaskViews {
    /// The rows of `source` in the board's columns, with the tasks closed in the last seven days in Done. `inPR` says
    /// whether a task's chat has its branch's pull request open. A column is worked out, never dragged to.
    package static func board(
        _ rows: [TaskRow], _ source: TaskSource, inPR: (TaskRow) -> Bool, now: Date = Date()
    ) -> [(column: TaskColumn, rows: [TaskRow])] {
        let week = now.timeIntervalSince1970 - 7 * 86_400
        let scope: (TaskRow) -> Bool = {
            switch source {
            case .project(let repo): $0.repo == repo
            case .tag(let tag): $0.tags.contains(tag)
            default: true
            }
        }
        var columns: [TaskColumn: [TaskRow]] = [:]
        for row in rows {
            let column: TaskColumn
            if row.task.state == .done {
                guard row.task.depth == 0, scope(row), (row.task.at ?? row.page.modified ?? 0) >= week else { continue }
                column = .done
            } else {
                guard source.holds(row) else { continue }
                if inPR(row) {
                    column = .pullRequest
                } else {
                    column =
                        switch row.work {
                        case .asks, .failed, .working: .working
                        case .review: .review
                        case .none: row.task.page == nil ? .ideas : .plan
                        }
                }
            }
            columns[column, default: []].append(row)
        }
        // A question goes first in its column, as an asking card does in the Agents Overview.
        return TaskColumn.allCases.map { c in
            (
                c,
                (columns[c] ?? []).enumerated().sorted { a, b in
                    (a.element.work == .asks ? 0 : 1, a.offset) < (b.element.work == .asks ? 0 : 1, b.offset)
                }.map(\.element)
            )
        }
    }
}
