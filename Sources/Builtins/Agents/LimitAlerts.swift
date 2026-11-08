import Core
import Foundation

/// Plan limits crossing a level (Settings › usage.alertAt, 80 % by default) or 95 %: one alert per level, until the limit
/// falls back 10 points under the lowest (its window reset).
struct LimitAlerts {
    struct Alert: Equatable { var agent: String, kind: String, percent: Double, level: Int, resets: String? }
    /// `first` and 95; none when `first` is nil (off).
    static func levels(first: Int?) -> [Int] { first.map { $0 < 95 ? [$0, 95] : [$0] } ?? [] }

    private var told: [String: Int] = [:]   // "agent|kind" → highest level already announced
    private var seeded = false

    /// The first reading only sets the baseline: what was already full when Kelp opened isn't news. Fresh ones only:
    /// a reading from over half an hour ago says nothing about now.
    mutating func update(_ u: UsageGet.Result, first: Int? = 80) -> [Alert] {
        let levels = Self.levels(first: first)
        var alerts: [Alert] = []
        for r in u.fresh() {
            let agent = r.agent, l = r.limit
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
