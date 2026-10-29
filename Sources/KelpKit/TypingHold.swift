import Foundation
import Core

/// Banners that wait while you type in Kelp: a finished or failed agent (and a limit warning) waits while a key was pressed
/// in the last 20 s, and goes out after 20 s without one, when Kelp goes to the back or another workspace comes up.
/// A question (Needs you) never waits; the sidebar and the Dock badge never wait either.
enum TypingHold {
    static let quiet: TimeInterval = 20

    static func holds(question: Bool, lastKey: Date?, active: Bool, now: Date = Date()) -> Bool {
        guard !question, active, let lastKey else { return false }
        return now.timeIntervalSince(lastKey) < quiet
    }

    /// "2 agents finished while you typed", a line each ("docs — Updated README", "perf — Failed: missing module"), up to 4.
    static func summary(_ lines: [(who: String, failed: Bool, text: String)]) -> (title: String, body: String) {
        let shown = lines.prefix(4).map { l in
            let text = l.text.isEmpty ? (l.failed ? String(localized: "ran into an error") : String(localized: "Ready for review"))
                : l.failed ? String(localized: "Failed: \(l.text)") : l.text
            return "\(l.who) — \(text)"
        }
        let more = lines.count > 4 ? [String(localized: "and \(lines.count - 4) more")] : []
        return (String(localized: "\(lines.count) agents finished while you typed"), (shown + more).joined(separator: "\n"))
    }
}
