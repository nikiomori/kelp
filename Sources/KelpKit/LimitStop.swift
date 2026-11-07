import Core
import Foundation

extension LimitHit {
    /// When it resets, if that can be told, read from when it stopped: "3pm" stays today's once that has passed.
    package var resetAt: Date? { resets.flatMap { ResetTime.parse($0, now: at) } }
}

/// What to say of a session a plan limit stopped: its row's line, its banner, its title (the Agents built-in's strip says
/// who could go on with its work).
package enum LimitStop {
    /// A time, with its date unless that's today.
    package static func clock(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        d.formatted(date: calendar.isDate(d, inSameDayAs: now) ? .omitted : .abbreviated, time: .shortened)
    }

    /// Its row's second line.
    static func rowLine(_ s: Session, now: Date = Date()) -> (word: String, text: String)? {
        guard let hit = s.limitHit else { return nil }
        if let at = s.continueAt {
            return (String(localized: "Continues"), String(localized: "at \(clock(at, now: now))"))
        }
        if let at = hit.resetAt, at <= now { return (String(localized: "Limit:"), String(localized: "has reset")) }
        let resets = hit.resetAt.map { clock($0, now: now) } ?? hit.resets
        return (String(localized: "Limit:"), resets.map { String(localized: "resets \($0)") } ?? hit.kind)
    }

    /// The banner's text: "5-hour · resets 3:40pm".
    static func banner(_ hit: LimitHit) -> String {
        hit.resets.map { String(localized: "\(hit.kind) · resets \($0)") } ?? hit.kind
    }

    package static func title(_ name: String, _ s: Session, now: Date = Date()) -> String {
        if let at = s.continueAt { return String(localized: "\(name) will continue at \(clock(at, now: now))") }
        if let at = s.limitHit?.resetAt, at <= now { return String(localized: "\(name): the limit has reset") }
        return String(localized: "\(name) hit its \(s.limitHit?.kind ?? "") limit")
    }
}
