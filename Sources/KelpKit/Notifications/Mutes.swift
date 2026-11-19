import Core
import Foundation

/// The sidebar rows the user muted (a project, a workspace or an agent), each until a date. A session is muted by its
/// own entry or by the entry of its workspace or project. Muting stops only the session's banners, their sound and the
/// Dock's bounce; its row and the Dock's badge still update. An entry whose date has passed no longer counts.
package enum Mutes {
    package static let forever = Date.distantFuture

    /// The choices in the Mute Notifications ▸ submenu, each with the date its mute ends.
    package static func choices(now: Date = Date(), calendar: Calendar = .current) -> [(title: String, until: Date)] {
        let midnight =
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86400)
        return [
            (String(localized: "For 1 Hour"), now.addingTimeInterval(3600)), (String(localized: "For Today"), midnight),
            (String(localized: "Until I Unmute"), forever)
        ]
    }

    static func covers(_ muted: [String: Date], _ ids: [String?], now: Date = Date()) -> Bool {
        ids.contains { id in id.flatMap { muted[$0] }.map { $0 > now } ?? false }
    }

    /// The mutes as `uiState` stores them, each date as seconds since 1970.
    static func value(_ m: [String: Date]) -> JSONValue { .object(m.mapValues { .double($0.timeIntervalSince1970) }) }
    static func read(_ v: JSONValue?) -> [String: Date] {
        guard case .object(let saved)? = v else { return [:] }
        return saved.compactMapValues { $0.number.map(Date.init(timeIntervalSince1970:)) }
    }

    /// The line the hover card shows for a muted row.
    static func line(until: Date) -> String {
        until == forever
            ? String(localized: "Notifications muted")
            : String(localized: "Notifications muted until \(until.formatted(date: .omitted, time: .shortened))")
    }

    /// Mutes these rows until `until`, as the row's menu does (the tile on the Dock strip has the same menu).
    @MainActor package static func mute(_ ids: [String], until: Date, in app: AppModel) {
        app.arrangement.mute(ids, until: until)
    }

    @MainActor package static func isMuted(_ session: Session, in app: AppModel) -> Bool {
        covers(app.arrangement.mutes, [session.id, session.worktreeId, app.worktree(session.worktreeId)?.repoId])
    }
}

extension Arrangement {
    /// Returns when the rows' own mute ends, or nil when they aren't muted.
    func mutedUntil(_ ids: [String]) -> Date? { ids.compactMap { mutes[$0] }.filter { $0 > Date() }.max() }

    /// Mutes the rows until `until`, and nil unmutes them. Each change also drops mutes that ran out and mutes of rows
    /// that are gone (a closed workspace, an ended agent).
    func mute(_ ids: [String], until: Date?) {
        var kept = mutes.filter { id, end in
            end > Date() && (app.session(id) != nil || app.worktree(id) != nil || app.repo(id) != nil)
        }
        for id in ids { kept[id] = until }
        mutes = kept
    }
}
