import Foundation
import Core

/// Rows told to keep quiet, each until a date: a project, a workspace or an agent. A session is muted by its own entry or
/// by what holds it. Only its banners, their sound and the Dock's bounce stop: its row and the Dock's badge go on as ever.
/// A date that passed just stops counting.
enum Mutes {
    static let key = "notifications.muted"
    static let forever = Date.distantFuture

    /// Mute Notifications ▸ …
    static func choices(now: Date = Date(), calendar: Calendar = .current) -> [(title: String, until: Date)] {
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86400)
        return [(String(localized: "For 1 Hour"), now.addingTimeInterval(3600)), (String(localized: "For Today"), midnight),
                (String(localized: "Until I Unmute"), forever)]
    }

    static func covers(_ muted: [String: Date], _ ids: [String?], now: Date = Date()) -> Bool {
        ids.contains { id in id.flatMap { muted[$0] }.map { $0 > now } ?? false }
    }

    /// As `uiState` keeps them: seconds since 1970.
    static func value(_ m: [String: Date]) -> JSONValue { .object(m.mapValues { .double($0.timeIntervalSince1970) }) }
    static func read(_ v: JSONValue?) -> [String: Date] {
        guard case .object(let o)? = v else { return [:] }
        return o.compactMapValues { $0.number.map(Date.init(timeIntervalSince1970:)) }
    }

    /// The hover card's line.
    static func line(until: Date) -> String {
        until == forever ? String(localized: "Notifications muted")
            : String(localized: "Notifications muted until \(until.formatted(date: .omitted, time: .shortened))")
    }
}

extension AppModel {
    func isMuted(_ s: Session) -> Bool { Mutes.covers(mutes, [s.id, s.worktreeId, worktree(s.worktreeId)?.repoId]) }

    /// When these rows' own mute ends; nil: they aren't.
    func mutedUntil(_ ids: [String]) -> Date? { ids.compactMap { mutes[$0] }.filter { $0 > Date() }.max() }

    /// nil unmutes. What ran out, and rows that are gone (a closed workspace, an ended agent), leave with each change.
    func mute(_ ids: [String], until: Date?) {
        var m = mutes.filter { id, end in end > Date() && (session(id) != nil || worktree(id) != nil || repo(id) != nil) }
        for id in ids { m[id] = until }
        mutes = m
    }
}
