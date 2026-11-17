import AppKit
import DesignKit
import KelpKit

/// An agent's fullest plan limit in a few words, such as "92 % · 3:40pm" or "Full · 3:40pm", shown where agents are
/// chosen. It uses the sidebar's numbers and colours. There is none for an unused plan, or for one read too long ago
/// to tell.
struct PlanNote: Equatable {
    let used: Double, resets: String?
    static let staleAfter: TimeInterval = 1800

    init?(fullest: (label: String, used: Double, resets: String?)?, readAt: Date?, now: Date = Date()) {
        guard let fullest, fullest.used > 0, now.timeIntervalSince(readAt ?? now) <= Self.staleAfter else { return nil }
        used = fullest.used
        resets = fullest.resets
    }

    private var isFull: Bool { used >= 1 }
    private var percent: String { "\(Int((used * 100).rounded())) %" }
    /// How full the limit is, without the reset time, for a half-width row that has no room for the time.
    var amount: String { isFull ? String(localized: "Full") : percent }
    var text: String { [amount, resets].compactMap { $0 }.joined(separator: " · ") }
    /// The reset time on its own, for a tip beside `amount`.
    var resetsTip: String? { resets.map { String(localized: "Resets \($0)") } }
    var color: NSColor { used >= 0.9 ? .textRed : used >= 0.7 ? .textOrange : .secondaryLabelColor }

    /// Returns the warning shown under the first-task field when the agent that field starts is nearly out of its
    /// plan.
    func warning(for name: String) -> String? {
        guard used >= 0.9 else { return nil }
        if isFull {
            return resets.map { String(localized: "\(name) is full until \($0).") }
                ?? String(localized: "\(name) is full.")
        }
        return resets.map { String(localized: "\(name) is at \(percent) until \($0).") }
            ?? String(localized: "\(name) is at \(percent).")
    }

    /// Returns the agent in `agents` with the most left, when that's over half. An agent with no reading can't be said
    /// to have any room.
    static func roomiest(_ agents: [String], notes: [String: PlanNote]) -> String? {
        agents.compactMap { a in notes[a].map { (a, $0.used) } }.filter { $0.1 < 0.5 }.min { $0.1 < $1.1 }?.0
    }

    /// The note as the shell shows it beside the agent (`PlanWords.notes`).
    var shown: AgentNote { (used, amount, text, resetsTip, color) }

    /// The answers the shell asks for about plan limits (`Contributions.plans`).
    @MainActor static func words(_ app: AppModel) -> PlanWords {
        PlanWords(
            notes: { UsageView.notes(app).mapValues(\.shown) },
            warning: { agent, name, others in
                let notes = UsageView.notes(app)
                guard let text = notes[agent]?.warning(for: name) else { return nil }
                return (text, roomiest(others, notes: notes))
            },
            rowLine: { LimitStop.rowLine($0) },
            title: { LimitStop.title($0, $1) },
            banner: { LimitStop.banner($0) })
    }
}
