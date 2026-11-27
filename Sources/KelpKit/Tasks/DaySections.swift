import Foundation

/// The days lists group things by, newest first, as Finder's Recents does: Today, Yesterday, Previous 7 Days, Earlier.
/// The Artifacts panel and Overview group pages by them, and the Tasks tab's logbook its closed lines.
package enum DaySections {
    /// The group of something that happened at `time` (seconds since 1970), seen at `now`.
    package nonisolated static func title(_ time: Double, now: Date, calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: time), today = calendar.startOfDay(for: now)
        if date >= today { return String(localized: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), date >= yesterday {
            return String(localized: "Yesterday")
        }
        if let week = calendar.date(byAdding: .day, value: -7, to: today), date >= week {
            return String(localized: "Previous 7 Days")
        }
        return String(localized: "Earlier")
    }
}
