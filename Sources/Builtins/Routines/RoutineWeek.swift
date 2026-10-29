import Foundation
import Core

/// The week on the Routines tab: a column a day, a mark a run. What ran comes from the runs; what will, from the schedule
/// (`Routine.next`, the function the daemon plans with).
struct RoutineWeek {
    struct Mark: Identifiable, Equatable {
        enum Kind: Equatable { case run(Routine.Run.Outcome), next, planned }
        let id: String, at: Date, kind: Kind, run: Routine.Run?
    }
    let days: [Date]
    let now: Date
    let calendar: Calendar

    /// The week `now` is in, as the person's calendar starts it.
    init(now: Date = Date(), calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
        let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    func isToday(_ day: Date) -> Bool { calendar.isDate(day, inSameDayAs: now) }

    /// The routine's runs that were due on `day`, then, from now on, when it's due (the very next time: `next`).
    func marks(_ r: Routine, runs: [Routine.Run], day: Date) -> [Mark] {
        guard let end = calendar.date(byAdding: .day, value: 1, to: day) else { return [] }
        var out = runs.filter { $0.routineId == r.id && $0.due >= day && $0.due < end }.sorted { $0.due < $1.due }
            .map { Mark(id: $0.id, at: $0.due, kind: .run($0.outcome), run: $0) }
        guard r.enabled, end > now else { return out }
        let next = r.next(after: now, calendar: calendar)
        for t in r.times(after: max(day.addingTimeInterval(-1), now), through: end.addingTimeInterval(-1), calendar: calendar) {
            out.append(Mark(id: "\(r.id)@\(t.timeIntervalSince1970)", at: t, kind: t == next ? .next : .planned, run: nil))
        }
        return out
    }

    /// "Weekdays at 9:00", "Every hour at :15", "Mondays at 10:00".
    static func schedule(_ r: Routine, calendar: Calendar = .current) -> String {
        let at = time(r.time)
        switch r.every {
        case .hourly: return String(localized: "Every hour at :\(String(format: "%02d", r.time % 60))")
        case .daily: return String(localized: "Every day at \(at)")
        case .weekdays: return String(localized: "Weekdays at \(at)")
        case .weekly:
            let day = calendar.weekdaySymbols[(r.weekday - 1) % 7]
            return String(localized: "\(day)s at \(at)")
        }
    }

    /// 540 → "9:00" in the person's clock (13:30 or 1:30 PM).
    static func time(_ minutes: Int) -> String {
        let d = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        return d.formatted(date: .omitted, time: .shortened)
    }
}
