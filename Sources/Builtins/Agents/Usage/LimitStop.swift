import Core
import Foundation
import KelpKit

extension LimitHit {
    /// When the limit resets, if that can be told. The time is read relative to when the session stopped, so "3pm"
    /// still means that day's 3pm once it has passed.
    var resetAt: Date? { resets.flatMap { ResetTime.parse($0, now: at) } }
}

/// The words for a session a plan limit stopped: the line on its row, its banner, and its title (`PlanWords`, for the
/// shell). Its strip also says who could go on with its work.
enum LimitStop {
    /// Formats a time, with its date unless the date is today.
    static func clock(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        date.formatted(date: calendar.isDate(date, inSameDayAs: now) ? .omitted : .abbreviated, time: .shortened)
    }

    /// The second line of the session's row.
    static func rowLine(_ session: Session, now: Date = Date()) -> (word: String, text: String)? {
        if let at = session.continueAt {   // at a limit's reset, or after an API error that passes
            return (String(localized: "Continues"), String(localized: "at \(clock(at, now: now))"))
        }
        guard let hit = session.limitHit else { return nil }
        if let at = hit.resetAt, at <= now { return (String(localized: "Limit:"), String(localized: "has reset")) }
        let resets = hit.resetAt.map { clock($0, now: now) } ?? hit.resets
        return (String(localized: "Limit:"), resets.map { String(localized: "resets \($0)") } ?? hit.kind)
    }

    /// The banner's text, such as "5-hour · resets 3:40pm".
    static func banner(_ hit: LimitHit) -> String {
        hit.resets.map { String(localized: "\(hit.kind) · resets \($0)") } ?? hit.kind
    }

    static func title(_ name: String, _ session: Session, now: Date = Date()) -> String {
        if let at = session.continueAt { return String(localized: "\(name) will continue at \(clock(at, now: now))") }
        if let at = session.limitHit?.resetAt, at <= now { return String(localized: "\(name): the limit has reset") }
        return String(localized: "\(name) hit its \(session.limitHit?.kind ?? "") limit")
    }
}
