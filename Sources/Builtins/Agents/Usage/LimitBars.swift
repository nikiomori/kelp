import Core
import Foundation

/// Which of an agent's plan limits get a bar in the sidebar's foot. By default each length of window (up to a day, up
/// to a week, longer or unknown) gets one bar, for its fullest limit, so Claude's 5 hours and its week both show, and
/// three weekly limits for three model groups show as one. The eye beside a limit in the hover card shows or hides its
/// bar. After the first click every limit of that agent keeps its choice, and a limit the agent reports later follows
/// the default.
enum LimitBars {
    typealias Line = UsageView.Line

    static func key(_ agent: String, _ kind: String) -> String { "\(agent)/\(kind)" }

    /// Returns 0 for a window of up to a day, 1 for up to 8 days, and 2 for a longer or unknown one.
    static func span(_ line: Line) -> Int {
        guard let window = line.window else { return 2 }
        return window <= 86400 ? 0 : window <= 8 * 86400 ? 1 : 2
    }

    static func isShown(_ line: Line, in lines: [Line], agent: String, shown: [String], hidden: [String]) -> Bool {
        let key = key(agent, line.kind)
        if shown.contains(key) { return true }
        if hidden.contains(key) { return false }
        let span = span(line)
        return lines.filter { Self.span($0) == span }.max { $0.used < $1.used }?.kind == line.kind
    }

    /// Returns the bars, the shortest window first and in the card's order within one. With every limit hidden it
    /// returns the fullest, so an agent's row never stands without a bar.
    static func bars(_ lines: [Line], agent: String, shown: [String], hidden: [String]) -> [Line] {
        let bars = lines.enumerated()
            .filter { isShown($0.element, in: lines, agent: agent, shown: shown, hidden: hidden) }
            .sorted { (span($0.element), $0.offset) < (span($1.element), $1.offset) }
            .map(\.element)
        return bars.isEmpty ? lines.max { $0.used < $1.used }.map { [$0] } ?? [] : bars
    }

    /// Returns the lists after a click on `line`'s eye, which flips its bar and writes down every limit of the agent as
    /// it now stands.
    static func toggled(_ line: Line, in lines: [Line], agent: String, shown: [String], hidden: [String])
        -> (shown: [String], hidden: [String])
    {
        let keys = Set(lines.map { key(agent, $0.kind) })
        var next = (shown: shown.filter { !keys.contains($0) }, hidden: hidden.filter { !keys.contains($0) })
        for other in lines {
            let on = isShown(other, in: lines, agent: agent, shown: shown, hidden: hidden) != (other.kind == line.kind)
            if on { next.shown.append(key(agent, other.kind)) } else { next.hidden.append(key(agent, other.kind)) }
        }
        return next
    }

    /// Returns the short name beside a bar's percent: "5h", "wk", "mo", or the model or pool a limit is for ("Fable"
    /// for Claude's "week · Fable", "Gemini" for Antigravity's "Gemini week").
    static func tag(_ kind: String) -> String {
        switch kind {
        case "session": String(localized: "5h", comment: "a 5-hour plan limit, beside its percent")
        case "week": String(localized: "wk", comment: "a weekly plan limit, beside its percent")
        case "month": String(localized: "mo", comment: "a monthly plan limit, beside its percent")
        default:
            if kind.hasPrefix("week · ") {
                String(kind.dropFirst(7))
            } else if kind.hasSuffix(" week") {
                String(kind.dropLast(5))
            } else {
                UsageView.label(kind)
            }
        }
    }
}
