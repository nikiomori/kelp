import AppKit
import Core
import DesignKit

/// Agents put out of the way: a "Parked" section at the bottom of the sidebar, no Done notifications, until a date or
/// until it needs you. One comes back by itself, with a "Back:" line saying why, when it asks, fails, or CI fails in its
/// folder. Kept in the daemon's UI state as `Mutes` keeps mutes (seconds since 1970; "until it needs me" is the far future).
enum Parking {
    static let key = "sessions.parked"

    /// Park ▸ …
    static func choices(now: Date = Date(), calendar: Calendar = .current) -> [(title: String, until: Date)] {
        let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now.addingTimeInterval(86400)) ?? now.addingTimeInterval(86400)
        return [(String(localized: "Until It Needs Me"), Mutes.forever), (String(localized: "For 1 Hour"), now.addingTimeInterval(3600)),
                (String(localized: "Until Tomorrow"), morning)]
    }

    /// The parked row's time: how long it stays out of the way.
    static func until(_ d: Date) -> String {
        d == Mutes.forever ? String(localized: "until it calls") : String(localized: "till \(d.formatted(date: .omitted, time: .shortened))")
    }
}

extension AppModel {
    /// Parked now: what ran out counts no more.
    var parkedIds: Set<String> { Set(parked.filter { $0.value > Date() }.keys) }
    func isParked(_ id: String) -> Bool { parked[id].map { $0 > Date() } ?? false }

    func park(_ id: String, until: Date) {
        parked = parked.filter { $0.value > Date() && session($0.key) != nil }.merging([id: until]) { $1 }
        parkedBack[id] = nil
    }

    /// A park "for 1 hour" ends on screen when its hour is up, not at the next refresh of something else.
    func endParksOnTime() {
        guard let next = parked.values.filter({ $0 > Date() && $0 != Mutes.forever }).min() else { return }
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(next.timeIntervalSinceNow + 0.5)) } catch { return }
            guard let self, self.parked.values.contains(where: { $0 <= Date() }) else { return }
            self.parked = self.parked.filter { $0.value > Date() }
        }
    }

    /// Back in its project; `back` says why on its row until it's opened.
    func unpark(_ id: String, back: String? = nil) {
        guard parked[id] != nil else { return }
        parked[id] = nil
        parkedBack[id] = back
    }

    /// A parked agent that asks or fails comes back by itself.
    func followParked(_ s: Session) {
        guard isParked(s.id) else { return }
        if s.status == .waiting { unpark(s.id, back: String(localized: "it asks you something")) }
        if s.status == .error { unpark(s.id, back: String(localized: "it failed")) }
    }

    /// CI that failed in a folder brings its parked agents back.
    func followParked(_ e: CIEvent) {
        guard e.result?.runs.first?.conclusion == "failure" else { return }
        for s in sessions where s.worktreeId == e.worktree && isParked(s.id) { unpark(s.id, back: String(localized: "CI failed")) }
    }
}

/// The "Parked" heading over the parked agents.
final class ParkedHeader: NSView {
    init(count: Int) {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: String(localized: "Parked"))
        title.font = .ui(11, weight: .semibold)
        let n = NSTextField(labelWithString: "\(count)")
        n.font = .uiDigits(11)
        n.textColor = .secondaryLabelColor
        let row = NSStackView(views: [title, n])
        row.spacing = Metrics.gap
        row.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        pin(row)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(String(localized: "Parked, \(count)"))
    }
    required init?(coder: NSCoder) { fatalError() }
}
