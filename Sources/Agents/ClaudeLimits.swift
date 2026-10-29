import Foundation

/// Claude Code prints plan usage in its UI ("You've used 80% of your weekly limit · resets Oct 20 at 5am (Europe/…)").
/// There's no other local source for those percentages, so sessions read them from their own output.
public enum ClaudeLimits {
    public struct Reading: Equatable, Sendable {
        public var kind: String       // "weekly", "session", "5-hour", "Opus weekly"…
        public var percent: Double
        public var resets: String?
    }

    private static let used = try? NSRegularExpression(pattern:
        #"(\d{1,3}(?:\.\d+)?)% of your ([A-Za-z0-9\- ]{1,30}?) limit(?:\s*[·∙•|-]\s*resets ([^\n(·]{2,40}))?"#)
    private static let reached = try? NSRegularExpression(pattern: #"([A-Za-z0-9\- ]{1,30}?) limit reached(?:\s*[·∙•|-]\s*resets ([^\n(·]{2,40}))?"#,
                                                          options: .caseInsensitive)

    public static func parse(_ text: String) -> [Reading] {
        let r = NSRange(text.startIndex..., in: text)
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            Range(m.range(at: i), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) }
        }
        var out = (used?.matches(in: text, range: r) ?? []).compactMap { m -> Reading? in
            guard let p = group(m, 1).flatMap(Double.init), let kind = group(m, 2) else { return nil }
            return Reading(kind: kind, percent: bounded(p), resets: group(m, 3))
        }
        out += (reached?.matches(in: text, range: r) ?? []).compactMap { m in
            group(m, 1).map { Reading(kind: $0.replacingOccurrences(of: "Claude AI usage", with: "usage"), percent: 100, resets: group(m, 2)) }
        }
        return out
    }

    /// Claude Code's `/usage` as `claude -p /usage` prints it: "Current session: 2% used · resets 7:40am (Europe/Helsinki)",
    /// "Current week (all models): 82% used · resets Oct 20 at 5am (…)", "Current week (Fable): 0% used · …".
    public static func parseUsage(_ text: String) -> [Reading] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let m = line.trimmingCharacters(in: .whitespaces)
                .wholeMatch(of: /Current (.+?): (\d{1,3}(?:\.\d+)?)% used(?: · resets (.+?))?(?: \(.*\))?/.ignoresCase()),
                let percent = Double(m.2) else { return nil }
            let label = String(m.1)
            let kind = label == "session" ? "session"
                : label.hasPrefix("week (all") ? "week"
                : label.hasPrefix("week (") ? "week · " + label.dropFirst(6).dropLast() : label
            return Reading(kind: kind, percent: bounded(percent), resets: m.3.map(String.init))
        }
    }

    /// Grok Build's `/usage` dialog: "Weekly limit (X Premium)", a bar with "45%", "Resets: October 24, 19:36".
    public static func parseGrokUsage(_ text: String) -> [Reading] {
        let lines = cells(text)
        guard let i = lines.lastIndex(where: { $0.hasPrefix("Weekly limit") }) else { return [] }
        var percent: Double?, resets: String?
        for next in lines[(i + 1)..<min(i + 4, lines.count)] {
            if percent == nil, let r = next.range(of: #"\d{1,3}(?:\.\d+)?%"#, options: .regularExpression) {
                percent = Double(next[r].dropLast()).map(bounded)
            }
            if next.hasPrefix("Resets:") { resets = next.dropFirst("Resets:".count).trimmingCharacters(in: .whitespaces) }
        }
        return percent.map { [Reading(kind: "week", percent: $0, resets: resets)] } ?? []
    }

    /// Antigravity's `/usage` as `agy -p /usage` prints it, a row per model group, tab-separated:
    /// "Gemini Models  Weekly Limit Remaining  9%  2026-10-30T21:42:00Z". A limit *remaining*, returned as used like the
    /// others ("Gemini week" 91 = 9% left), and the reset as Claude writes one ("Oct 30 at 9:42pm", local time).
    public static func parseAntigravityUsage(_ text: String, timeZone: TimeZone = .current) -> [Reading] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone
        f.dateFormat = "MMM d 'at' h:mma"; f.amSymbol = "am"; f.pmSymbol = "pm"
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let cell = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cell.count >= 3, cell[1].localizedCaseInsensitiveContains("remaining"), cell[2].hasSuffix("%"),
                  let left = Double(cell[2].dropLast()) else { return nil }
            let group = cell[0].split(separator: " ").first.map { $0.capitalized } ?? "Models"
            let resets = cell.count > 3 ? ISO8601DateFormatter().date(from: cell[3]).map(f.string) : nil
            return Reading(kind: "\(group) week", percent: bounded(100 - left), resets: resets)
        }
    }

    /// Kimi Code's `/usage`: under "Plan usage", rows like "5h limit  ███░…  20% used  resets in 1h" (and Weekly / Monthly).
    public static func parseKimiUsage(_ text: String) -> [Reading] {
        let lines = text.components(separatedBy: CharacterSet(charactersIn: "\n│┃║"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let start = lines.lastIndex(where: { $0 == "Plan usage" }) else { return [] }
        var out: [Reading] = []
        for line in lines[(start + 1)...] {
            if line == "Session usage" || line == "Context window" || line == "Extra Usage" { break }
            guard let pct = line.range(of: #"\d{1,3}(?:\.\d+)?% used"#, options: .regularExpression),
                  let percent = Double(line[pct].dropLast("% used".count)) else { continue }
            let before = line[..<pct.lowerBound]
            let label = before.replacingOccurrences(of: #"[█░]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces).lowercased()
            let kind: String = if label.hasPrefix("5h") || label.hasPrefix("5-hour") { "session" }
                else if label.hasPrefix("weekly") { "week" }
                else if label.hasPrefix("monthly") { "month" }
                else if label.isEmpty { "plan" } else { label }
            var resets: String?
            if let r = line.range(of: #"(?i)resets in .+$"#, options: .regularExpression) {
                resets = String(line[r].dropFirst("resets ".count))
            } else if line.range(of: #"(?i)\breset\b"#, options: .regularExpression) != nil {
                resets = "now"
            }
            out.append(Reading(kind: kind, percent: bounded(percent), resets: resets))
        }
        return out
    }

    /// GitHub Copilot's `/usage`: a row like "Plan ■■■■■■ 2% used 5 / 200 AIC" (AI credits), maybe with "resets in …".
    public static func parseCopilotUsage(_ text: String) -> [Reading] {
        var found: [String: Reading] = [:], order: [String] = []
        let lines = text.components(separatedBy: CharacterSet(charactersIn: "\n│┃║"))
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let pct = line.range(of: #"\d{1,3}(?:\.\d+)?% used"#, options: .regularExpression),
                  let percent = Double(line[pct].dropLast("% used".count)) else { continue }
            let label = line[..<pct.lowerBound].replacingOccurrences(of: #"[■□█░▒▓▪▫]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces).lowercased()
            guard label.isEmpty || label.count <= 30 else { continue }
            let kind = label.isEmpty ? "plan" : label
            let resets = line.firstMatch(of: /(?i)resets?\s+((?:in|on|at)\s[^─│╮╭╯╰]+)/).map { $0.1.trimmingCharacters(in: .whitespaces) }
            if found[kind] == nil { order.append(kind) }
            found[kind] = Reading(kind: kind, percent: bounded(percent), resets: resets)
        }
        return order.compactMap { found[$0] }
    }

    /// Cursor Agent's `/usage`: "Usage • Free  Resets Nov 23", then "Included 0% used ░░░", "Auto 0% used", "API 0% used" (the
    /// plan's monthly pools); "On-Demand" has no percentage.
    public static func parseCursorUsage(_ text: String) -> [Reading] {
        let lines = text.components(separatedBy: CharacterSet(charactersIn: "\n│┃║")).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let head = lines.lastIndex(where: { $0.hasPrefix("Usage") && $0.contains("Resets") }) else { return [] }
        let resets = lines[head].firstMatch(of: /Resets\s+(.+?)\s*$/).map { String($0.1) }
        var found: [String: Reading] = [:], order: [String] = []
        for line in lines[(head + 1)...] {
            guard let m = line.firstMatch(of: /^([A-Za-z][A-Za-z ]{0,20}?)\s+(\d{1,3}(?:\.\d+)?)% used/), let p = Double(m.2) else { continue }
            let kind = m.1 == "Included" ? "month" : String(m.1)
            if found[kind] == nil { order.append(kind) }
            found[kind] = Reading(kind: kind, percent: bounded(p), resets: resets)
        }
        return order.compactMap { found[$0] }
    }

    /// What a Cursor Agent session prints when the plan ran out: "You've hit your usage limit … Your usage limits will reset when
    /// your monthly cycle ends on 11/23/2026." Its `/usage` still says "Included 0% used" on the Free plan, so this is the only sign.
    /// `resets` as `/usage` writes it ("Nov 23").
    public static func parseCursorLimitHit(_ text: String) -> Reading? {
        guard text.contains("hit your usage limit") || text.contains("hit your free requests limit") else { return nil }
        let date = text.firstMatch(of: /cycle\s+ends\s+on\s+(\d{1,2})\/(\d{1,2})\/\d{4}/)
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let resets = date.flatMap { m in Int(m.1).flatMap { (1...12).contains($0) ? "\(months[$0 - 1]) \(Int(m.2) ?? 0)" : nil } }
        return Reading(kind: "month", percent: 100, resets: resets)
    }

    /// A TUI's text in pieces: lines, split again at dialog borders (│) and wide gaps between columns.
    static func cells(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "\n│┃║"))
            .flatMap { $0.components(separatedBy: "   ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func bounded(_ percent: Double) -> Double { min(max(percent, 0), 100) }
}
