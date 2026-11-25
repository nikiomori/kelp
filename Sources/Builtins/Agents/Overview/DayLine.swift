import Core
import Foundation

/// A chat's time as the Agents Overview draws it, worked out from its status changes (`session.history`): when its
/// agent worked, when it waited for the user between two turns, and whether it asks now.
struct DayLine: Equatable {
    enum Kind { case worked, waited, waitsNow }
    struct Span: Equatable {
        var from: Date, to: Date, kind: Kind
        var length: TimeInterval { to.timeIntervalSince(from) }
    }
    var spans: [Span] = []
    /// How many times the agent started working.
    var turns = 0

    /// A rest between two turns longer than this was the user away, not the agent waiting for them.
    static let away: TimeInterval = 3 * 3600

    var worked: TimeInterval { spans.filter { $0.kind == .worked }.reduce(0) { $0 + $1.length } }
    var waited: TimeInterval { spans.filter { $0.kind != .worked }.reduce(0) { $0 + $1.length } }
    /// How long the agent has asked, while it asks now.
    var waitsNow: TimeInterval? { spans.last.flatMap { $0.kind == .waitsNow ? $0.length : nil } }

    /// Reads `changes` (oldest first), the last one lasting until `now`. A rest counts as waiting only between two
    /// turns, and only while shorter than `away`; a rest after the last turn counts only while the agent asks.
    static func of(_ changes: [SessionHistory.Change], now: Date) -> DayLine {
        var rests: [(from: Date, to: Date, working: Bool, status: AgentStatus)] = []
        for (i, change) in changes.enumerated() {
            let to = i + 1 < changes.count ? changes[i + 1].at : now
            guard to > change.at else { continue }
            let working = change.status == .working
            if let last = rests.last, last.working == working {
                rests[rests.count - 1].to = to
                rests[rests.count - 1].status = change.status
            } else {
                rests.append((change.at, to, working, change.status))
            }
        }
        var line = DayLine()
        for (i, part) in rests.enumerated() {
            if part.working {
                line.spans.append(.init(from: part.from, to: part.to, kind: .worked))
                line.turns += 1
            } else if i > 0, i + 1 < rests.count, part.to.timeIntervalSince(part.from) < away {
                line.spans.append(.init(from: part.from, to: part.to, kind: .waited))
            } else if i + 1 == rests.count, part.status == .waiting {
                line.spans.append(.init(from: part.from, to: part.to, kind: .waitsNow))
            }
        }
        return line
    }

    /// How many lines' agents worked at once, at each `step` from `from` to `to`.
    static func atOnce(_ lines: [DayLine], from: Date, to: Date, step: TimeInterval) -> [Int] {
        guard step > 0, to > from else { return [] }
        let worked = lines.flatMap { $0.spans.filter { $0.kind == .worked } }
        return stride(from: from, to: to, by: step).map { at in
            worked.filter { $0.from < at.addingTimeInterval(step) && $0.to > at }.count
        }
    }

    /// The longest waits of all lines, longest first, each with whose line it is.
    static func longestWaits(_ lines: [String: DayLine], count: Int) -> [(session: String, span: Span)] {
        let waits = lines.flatMap { id, line in line.spans.filter { $0.kind != .worked }.map { (id, $0) } }
        return Array(waits.sorted { $0.1.length > $1.1.length }.prefix(count))
    }
}

/// What the overview's week sums up: by day, and by project.
enum WeekSums {
    struct Day: Equatable, Identifiable {
        var day: Date
        var worked: TimeInterval = 0, waited: TimeInterval = 0
        var chats = 0
        var id: Date { day }
    }
    struct Project: Equatable, Identifiable {
        var name: String
        var chats = 0
        var worked: TimeInterval = 0, waited: TimeInterval = 0
        var id: String { name }
    }

    /// The last `days` days up to `now`'s, oldest first. A span counts on the day it began.
    static func days(_ lines: [String: DayLine], days: Int, now: Date, calendar: Calendar = .current) -> [Day] {
        let today = calendar.startOfDay(for: now)
        var out = (0..<days).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
            .map { Day(day: $0) }
        for line in lines.values {
            var seen: Set<Int> = []
            for span in line.spans {
                guard let i = out.firstIndex(where: { $0.day == calendar.startOfDay(for: span.from) }) else { continue }
                if span.kind == .worked { out[i].worked += span.length } else { out[i].waited += span.length }
                if seen.insert(i).inserted { out[i].chats += 1 }
            }
        }
        return out
    }

    /// One row per project (`project` names each line's), the most worked first.
    static func projects(_ lines: [String: DayLine], project: (String) -> String?) -> [Project] {
        var rows: [String: Project] = [:]
        for (id, line) in lines where !line.spans.isEmpty {
            guard let name = project(id) else { continue }
            rows[name, default: Project(name: name)].chats += 1
            rows[name]?.worked += line.worked
            rows[name]?.waited += line.waited
        }
        return rows.values.sorted { ($0.worked, $0.name) > ($1.worked, $1.name) }
    }
}
