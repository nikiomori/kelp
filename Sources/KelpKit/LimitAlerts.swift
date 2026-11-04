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
        let fresh = { (agent: String) in u.plansReadAt?[agent].map { now.timeIntervalSince1970 - $0 <= 1800 } ?? true }
        var out: [(agent: String, limit: UsageGet.Limit, resetAt: Date?)] = []
        func add(_ agent: String, _ ls: [UsageGet.Limit]) {
            out += ls.map { (agent, $0, $0.resets.flatMap { ResetTime.parse($0, now: now) }) }
        }
        for (agent, ls) in u.plans ?? [:] where agent != "claude" && fresh(agent) { add(agent, ls) }
        if fresh("claude") { add("claude", u.plans?["claude"] ?? u.claudeLimits ?? []) }
        if let x = u.codex.first, now.timeIntervalSince1970 - x.observedAt <= 1800 {
            let at = { (t: Double?) in t.map { Date(timeIntervalSince1970: $0) } }
            let kind = UsageGet.Codex.kind
            if let p = x.primaryUsedPercent {
                out.append(("codex", .init(kind: kind(x.primaryWindowMinutes, true), percent: p, resets: nil), at(x.primaryResetsAt)))
            }
            if let p = x.secondaryUsedPercent {
                out.append(("codex", .init(kind: kind(x.secondaryWindowMinutes, false), percent: p, resets: nil), at(x.secondaryResetsAt)))
            }
        }
        return out
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
