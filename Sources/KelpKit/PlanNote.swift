import AppKit
import DesignKit

/// An agent's fullest plan limit in a few words, where agents are chosen: "92 % · 3:40pm", "Full · 3:40pm". The sidebar's
/// numbers and colours; none for a plan unused, or read too long ago to tell.
package struct PlanNote: Equatable {
    let used: Double, resets: String?
    static let staleAfter: TimeInterval = 1800

    package init?(fullest: (label: String, used: Double, resets: String?)?, readAt: Date?, now: Date = Date()) {
        guard let fullest, fullest.used > 0, now.timeIntervalSince(readAt ?? now) <= Self.staleAfter else { return nil }
        used = fullest.used
        resets = fullest.resets
    }

    private var isFull: Bool { used >= 1 }
    private var percent: String { "\(Int((used * 100).rounded())) %" }
    /// How full, without when it resets: where a half-width row has no room for the time.
    var amount: String { isFull ? String(localized: "Full") : percent }
    package var text: String { [amount, resets].compactMap { $0 }.joined(separator: " · ") }
    /// The reset time on its own, for a tip beside `amount`.
    var resetsTip: String? { resets.map { String(localized: "Resets \($0)") } }
    package var color: NSColor { used >= 0.9 ? .textRed : used >= 0.7 ? .textOrange : .secondaryLabelColor }

    /// Said under the first-task field when the agent it starts is nearly out.
    func warning(for name: String) -> String? {
        guard used >= 0.9 else { return nil }
        if isFull {
            return resets.map { String(localized: "\(name) is full until \($0).") }
                ?? String(localized: "\(name) is full.")
        }
        return resets.map { String(localized: "\(name) is at \(percent) until \($0).") }
            ?? String(localized: "\(name) is at \(percent).")
    }

    /// The agent with the most left of `agents`, when that's a lot: one with no reading can't be said to have any.
    static func roomiest(_ agents: [String], notes: [String: PlanNote]) -> String? {
        agents.compactMap { a in notes[a].map { (a, $0.used) } }.filter { $0.1 < 0.5 }.min { $0.1 < $1.1 }?.0
    }
}

extension AppModel {
    /// What's said beside an agent where agents are chosen (`Contributions.planNotes`); none without a built-in to say.
    var planNotes: [String: PlanNote] { extensions.all.planNotes?() ?? [:] }
}
