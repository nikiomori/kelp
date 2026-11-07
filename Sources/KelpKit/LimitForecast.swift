import Core
import Foundation

/// When a plan limit will be full at the pace it's filling, and whether that comes before it resets. Readings arrive every
/// ten minutes or so; the pace is the rise over the last two hours (a window that reset starts again), or, until there are
/// eight minutes of those, the window's average since it began: that needs one reading, so it tells right after launch.
struct LimitForecast {
    private var samples: [String: [(at: Date, percent: Double)]] = [:]
    static let span: TimeInterval = 2 * 3600

    static func key(_ agent: String, _ kind: String) -> String { agent + "|" + kind }

    mutating func record(_ u: UsageGet.Result, now: Date = Date()) {
        for (agent, l, _) in LimitAlerts.readings(u, now: now) {
            let k = Self.key(agent, l.kind)
            var s = samples[k] ?? []
            if let last = s.last {
                if l.percent < last.percent {
                    s = []
                }   // its window reset
                else if now.timeIntervalSince(last.at) < 120 {
                    continue
                }   // one push per read is enough
            }
            s.append((now, l.percent))
            samples[k] = s.filter { now.timeIntervalSince($0.at) <= Self.span }
        }
    }

    /// The latest reading and how fast it rises (points a second). `resetAt` and `window` give the window's average pace.
    private func pace(_ key: String, resetAt: Date?, window: TimeInterval?, now: Date) -> (
        last: (at: Date, percent: Double), rate: Double
    )? {
        guard let s = samples[key], let first = s.first, let last = s.last else { return nil }
        if last.at.timeIntervalSince(first.at) >= 480 {
            return (last, (last.percent - first.percent) / now.timeIntervalSince(first.at))   // idle time since counted
        }
        // Too early in the window, the average says little (one prompt in its first minutes would fill it "in an hour").
        guard let resetAt, let window, window > 0 else { return nil }
        let gone = window - resetAt.timeIntervalSince(last.at)
        guard gone >= max(480, window * 0.05), gone <= window else { return nil }
        return (last, last.percent / gone)
    }

    /// Seconds until it's full at its pace; nil when it isn't rising or there's too little to tell.
    func untilFull(_ key: String, resetAt: Date? = nil, window: TimeInterval? = nil, now: Date = Date())
        -> TimeInterval?
    {
        guard let p = pace(key, resetAt: resetAt, window: window, now: now), p.rate > 0, p.last.percent < 100 else {
            return nil
        }
        return (100 - p.last.percent) / p.rate - now.timeIntervalSince(p.last.at)
    }

    /// Where it ends up at its pace when it resets, in percent; nil when that can't be told.
    func atReset(_ key: String, resetAt: Date?, window: TimeInterval?, now: Date = Date()) -> Double? {
        guard let resetAt, let p = pace(key, resetAt: resetAt, window: window, now: now) else { return nil }
        return p.last.percent + max(0, p.rate) * resetAt.timeIntervalSince(p.last.at)
    }

    /// The time to say "full in …" for: it fills before it resets (at `resetAt`), within a day.
    func warning(_ key: String, resetAt: Date?, window: TimeInterval? = nil, now: Date = Date()) -> TimeInterval? {
        guard let resetAt, let eta = untilFull(key, resetAt: resetAt, window: window, now: now), eta > 0,
            eta < 24 * 3600,
            now.addingTimeInterval(eta) < resetAt
        else { return nil }
        return eta
    }

    /// A window longer than a day that resets within one with over half of it left: what isn't used goes with the reset.
    /// Not the 5-hour session, which comes back all day.
    static func unusedNearReset(percent: Double, resetAt: Date?, window: TimeInterval?, now: Date = Date()) -> Bool {
        guard let resetAt, let window, window > 86400 else { return false }
        let left = resetAt.timeIntervalSince(now)
        return left > 0 && left <= 86400 && percent < 50
    }

    static func duration(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded(.up))
        return m < 60
            ? String(localized: "\(m) min")
            : m < 36 * 60 ? String(localized: "\(m / 60) h \(m % 60) min") : String(localized: "\(m / 1440) days")
    }
}
