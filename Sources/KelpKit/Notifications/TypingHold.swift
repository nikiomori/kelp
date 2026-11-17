import Core
import Foundation

/// Holds banners back while you type in Kelp. A finished or failed agent (and a limit warning) waits while a key was
/// pressed in the last 20 s. It goes out after 20 s without a key, when Kelp goes to the back, or when another
/// workspace comes up. A question (Needs you) never waits, and neither do the sidebar and the Dock badge.
enum TypingHold {
    static let quiet: TimeInterval = 20

    static func holds(question: Bool, lastKey: Date?, active: Bool, now: Date = Date()) -> Bool {
        guard !question, active, let lastKey else { return false }
        return now.timeIntervalSince(lastKey) < quiet
    }

    /// Builds the held banner: the title "2 agents finished while you typed" and a line for each agent, up to 4
    /// ("docs — Updated README", "perf — Failed: missing module").
    static func summary(_ lines: [(who: String, failed: Bool, text: String)]) -> (title: String, body: String) {
        let shown = lines.prefix(4).map { line in
            let text =
                line.text.isEmpty
                ? (line.failed ? String(localized: "ran into an error") : String(localized: "Ready for review"))
                : line.failed ? String(localized: "Failed: \(line.text)") : line.text
            return "\(line.who) — \(text)"
        }
        let more = lines.count > 4 ? [String(localized: "and \(lines.count - 4) more")] : []
        return (
            String(localized: "\(lines.count) agents finished while you typed"), (shown + more).joined(separator: "\n")
        )
    }
}
