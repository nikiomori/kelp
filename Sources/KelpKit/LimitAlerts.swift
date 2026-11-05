import Foundation
import Core

/// Plan limits crossing a level (Settings › usage.alertAt, 80 % by default) or 95 %: one alert per level, until the limit
/// falls back 10 points under the lowest (its window reset).
struct LimitAlerts {
    struct Alert: Equatable { var agent: String, kind: String, percent: Double, level: Int, resets: String? }
    /// `first` and 95; none when `first` is nil (off).
    static func levels(first: Int?) -> [Int] { first.map { $0 < 95 ? [$0, 95] : [$0] } ?? [] }

    private var told: [String: Int] = [:]   // "agent|kind" → highest level already announced
    private var seeded = false

    /// Every limit the agents report now, as the sidebar's rings show them, with when it resets if that can be told.
    /// Not the ones the sidebar dims: a reading from more than half an hour ago says nothing about now.
    static func readings(_ u: UsageGet.Result, now: Date = Date()) -> [(agent: String, limit: UsageGet.Limit, resetAt: Date?)] {
        u.readings(now: now).filter { $0.readAt.map { now.timeIntervalSince($0) <= 1800 } ?? true }.map { ($0.agent, $0.limit, $0.resetAt) }
    }

    /// The first reading only sets the baseline: what was already full when Kelp opened isn't news.
    mutating func update(_ u: UsageGet.Result, first: Int? = 80) -> [Alert] {
        let levels = Self.levels(first: first)
        var alerts: [Alert] = []
        for (agent, l, _) in Self.readings(u) {
            let key = agent + "|" + l.kind
            let level = levels.last { l.percent >= Double($0) } ?? 0
            if l.percent < Double((levels.first ?? 100) - 10) { told[key] = nil }
            guard level > (told[key] ?? 0) else { continue }
            told[key] = level
            if seeded { alerts.append(Alert(agent: agent, kind: l.kind, percent: l.percent, level: level, resets: l.resets)) }
        }
        seeded = true
        return alerts
    }
}
