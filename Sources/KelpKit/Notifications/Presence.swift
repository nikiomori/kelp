import CoreGraphics
import Foundation

/// Tells whether someone is at the Mac: a key was pressed or the pointer moved in the last three minutes, and the
/// screen isn't locked. Only then does a finished agent count as read (`Glances`), so a window left open in an empty
/// room marks nothing as read. When presence can't be told, it counts as away, because unread is the safe side.
enum Presence {
    static let recent: TimeInterval = 180

    static func here() -> Bool {
        let idle = CGEventType(rawValue: ~0).map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return decide(idle: idle, locked: session.map { $0["CGSSessionScreenIsLocked"] as? Bool ?? false })
    }

    /// Decides from `idle` (seconds since the last input) and `locked` (nil when the login session can't be read).
    static func decide(idle: TimeInterval?, locked: Bool?) -> Bool {
        guard let idle, idle.isFinite, idle >= 0, idle < recent, let locked else { return false }
        return !locked
    }
}
