import CoreGraphics
import Foundation

/// Whether someone is at the Mac: a key or the pointer moved in the last three minutes, and the screen isn't locked. A
/// finished agent counts as read only then (`Glances`), so a window left open in an empty room reads nothing. What can't
/// be told counts as away: unread is the safe side.
enum Presence {
    static let recent: TimeInterval = 180

    static func here() -> Bool {
        let idle = CGEventType(rawValue: ~0).map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return decide(idle: idle, locked: session.map { $0["CGSSessionScreenIsLocked"] as? Bool ?? false })
    }

    /// `idle`: seconds since the last input; `locked`: nil when the session can't be read.
    static func decide(idle: TimeInterval?, locked: Bool?) -> Bool {
        guard let idle, idle.isFinite, idle >= 0, idle < recent, let locked else { return false }
        return !locked
    }
}
