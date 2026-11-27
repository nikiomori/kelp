import Core
import Foundation

/// The board's columns, as the Agents Overview's stages, with two before them for work no agent has started: an idea
/// (a line), and a plan (a line that grew into a page).
enum TaskColumn: Int, CaseIterable, Sendable {
    case ideas, plan, working, review, pullRequest, done

    var title: String {
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
    static func board(
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
