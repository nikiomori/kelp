import Core
import Foundation

/// Raises alerts when a plan limit crosses a level: the one set in Settings (usage.alertAt, 80 % by default), or 95 %.
/// Each level alerts once, until the limit falls 10 points below the lowest level, which means its window reset.
struct LimitAlerts {
    struct Alert: Equatable { var agent: String, kind: String, percent: Double, level: Int, resets: String? }
    /// Returns the levels to alert at, `first` and 95. Returns none when `first` is nil, because alerts are off.
    static func levels(first: Int?) -> [Int] { first.map { $0 < 95 ? [$0, 95] : [$0] } ?? [] }

    private var told: [String: Int] = [:]   // "agent|kind" → highest level already announced
    private var seeded = false

    /// Returns the new alerts for `result`. The first reading only sets the baseline, because a limit already full
    /// when Kelp opened isn't news. Only fresh readings count, because a reading from over half an hour ago says
    /// nothing about now.
    mutating func update(_ result: UsageGet.Result, first: Int? = 80) -> [Alert] {
        let levels = Self.levels(first: first)
        var alerts: [Alert] = []
        for reading in result.fresh() {
            let agent = reading.agent, l = reading.limit
            let key = agent + "|" + l.kind
            let level = levels.last { l.percent >= Double($0) } ?? 0
            if l.percent < Double((levels.first ?? 100) - 10) { told[key] = nil }
            guard level > (told[key] ?? 0) else { continue }
            told[key] = level
            if seeded {
                alerts.append(Alert(agent: agent, kind: l.kind, percent: l.percent, level: level, resets: l.resets))
            }
        }
        seeded = true
        return alerts
    }
}
