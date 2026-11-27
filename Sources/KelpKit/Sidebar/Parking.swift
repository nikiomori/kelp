import AppKit
import Core
import DesignKit

/// Agents put out of the way, until a date or until they need you. They sit in a "Parked" section at the bottom of the
/// sidebar and send no Done notifications. A parked agent comes back by itself, with a "Back:" line saying why, when it
/// asks, fails, or CI fails in its folder. Parks are kept in the daemon's UI state the way `Mutes` keeps mutes (seconds
/// since 1970, and "until it needs me" is the far future).
enum Parking {
    static let key = "sessions.parked"

    /// The choices in the Park ▸ menu: each title and the date the park lasts until.
    static func choices(now: Date = Date(), calendar: Calendar = .current) -> [(title: String, until: Date)] {
        let morning =
            calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now.addingTimeInterval(86400))
            ?? now.addingTimeInterval(86400)
        return [
            (String(localized: "Until It Needs Me"), Mutes.forever),
            (String(localized: "For 1 Hour"), now.addingTimeInterval(3600)),
            (String(localized: "Until Tomorrow"), morning)
        ]
    }

    /// The time on a parked row, which says how long the agent stays out of the way.
    static func until(_ d: Date) -> String {
        d == Mutes.forever
            ? String(localized: "until it calls")
            : String(localized: "till \(d.formatted(date: .omitted, time: .shortened))")
    }
}

extension Arrangement {
    /// The agents parked now. A park that ran out no longer counts.
    var parkedIds: Set<String> { Set(parked.filter { $0.value > Date() }.keys) }
    func isParked(_ id: String) -> Bool { parked[id].map { $0 > Date() } ?? false }

    func park(_ id: String, until: Date) {
        parked = parked.filter { $0.value > Date() && app.session($0.key) != nil }.merging([
            id: until
        ]) { $1 }
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

    /// Puts an agent back in its project. `back` says why, on the agent's row, until the agent is opened.
    func unpark(_ id: String, back: String? = nil) {
        guard parked[id] != nil else { return }
        parked[id] = nil
        parkedBack[id] = back
    }

    /// A parked agent that asks or fails comes back by itself.
    func followParked(_ session: Session) {
        guard isParked(session.id) else { return }
        if session.status == .waiting { unpark(session.id, back: String(localized: "it asks you something")) }
        if session.status == .error { unpark(session.id, back: String(localized: "it failed")) }
    }

    /// Brings back the parked agents of a folder where a run newly failed. It looks at the newest run of each
    /// workflow, as the daemon and the marks read the branch's CI (`CIRuns.latest`), and compares their failures with
    /// the folder's last reading: an old failure still stored, while another workflow starts or the value is read
    /// again, isn't news. The first reading since launch only sets what was known.
    func followParked(_ ciEvent: CIEvent) {
        let failed = Set(CIRuns.latest(ciEvent.result?.runs ?? []).filter { $0.conclusion == "failure" }.map(\.id))
        let before = ciFailed.updateValue(failed, forKey: ciEvent.worktree)
        guard let before, !failed.subtracting(before).isEmpty else { return }
        for s in app.sessions where app.gitKey(s.worktreeId) == ciEvent.worktree && isParked(s.id) {
            unpark(s.id, back: String(localized: "CI failed"))
        }
    }
}

/// The "Parked" heading above the parked agents.
final class ParkedHeader: NSView {
    init(count: Int) {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: String(localized: "Parked"))
        title.font = .ui(TextSize.caption, weight: .semibold)
        title.textColor = .secondaryLabelColor   // as "Projects" above the list
        let number = NSTextField(labelWithString: "\(count)")
        number.font = .uiDigits(TextSize.caption)
        number.textColor = .secondaryLabelColor
        let row = NSStackView(views: [title, number])
        row.spacing = Metrics.gap
        row.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        pin(row)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(String(localized: "Parked, \(count)"))
    }
    required init?(coder: NSCoder) { fatalError() }
}
