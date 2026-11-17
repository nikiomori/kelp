import Core
import DesignKit
import Foundation

/// Works out when a plan limit will be full at the pace it is filling, and whether that comes before it resets.
/// Readings arrive every ten minutes or so. The pace is the rise over the last two hours, counted afresh when the
/// window resets. Until those readings span eight minutes, the pace is the window's average since it began. The
/// average needs only one reading, so the forecast works right after launch.
struct LimitForecast {
    private var samples: [String: [(at: Date, percent: Double)]] = [:]
    static let span: TimeInterval = 2 * 3600

    static func key(_ agent: String, _ kind: String) -> String { agent + "|" + kind }

    mutating func record(_ usage: UsageGet.Result, now: Date = Date()) {
        for reading in usage.fresh(now: now) {
            let limit = reading.limit, key = Self.key(reading.agent, limit.kind)
            var series = samples[key] ?? []
            if let last = series.last {
                if limit.percent < last.percent {
                    series = []
                }   // the limit's window reset
                else if now.timeIntervalSince(last.at) < 120 {
                    continue
                }   // a sample within two minutes of the last adds nothing
            }
            series.append((now, limit.percent))
            samples[key] = series.filter { now.timeIntervalSince($0.at) <= Self.span }
        }
    }

    /// Returns the latest reading and how fast the limit rises, in points a second. `resetAt` and `window` give the
    /// window's average pace, which is used while the readings are too few.
    private func pace(_ key: String, resetAt: Date?, window: TimeInterval?, now: Date) -> (
        last: (at: Date, percent: Double), rate: Double
    )? {
        guard let series = samples[key], let first = series.first, let last = series.last else { return nil }
        if last.at.timeIntervalSince(first.at) >= 480 {
            return (last, (last.percent - first.percent) / now.timeIntervalSince(first.at))   // counts idle time too
        }
        // Early in the window the average says little, because one prompt in its first minutes would fill it "in an
        // hour".
        guard let resetAt, let window, window > 0 else { return nil }
        let gone = window - resetAt.timeIntervalSince(last.at)
        guard gone >= max(480, window * 0.05), gone <= window else { return nil }
        return (last, last.percent / gone)
    }

    /// Returns the seconds until the limit is full at its pace, or nil when it isn't rising or there's too little to
    /// tell.
    func untilFull(_ key: String, resetAt: Date? = nil, window: TimeInterval? = nil, now: Date = Date())
        -> TimeInterval?
    {
        guard let trend = pace(key, resetAt: resetAt, window: window, now: now), trend.rate > 0,
            trend.last.percent < 100
        else {
            return nil
        }
        return (100 - trend.last.percent) / trend.rate - now.timeIntervalSince(trend.last.at)
    }

    /// Returns the percent the limit reaches at its pace by the time it resets, or nil when that can't be told.
    func atReset(_ key: String, resetAt: Date?, window: TimeInterval?, now: Date = Date()) -> Double? {
        guard let resetAt, let trend = pace(key, resetAt: resetAt, window: window, now: now) else { return nil }
        return trend.last.percent + max(0, trend.rate) * resetAt.timeIntervalSince(trend.last.at)
    }

    /// Returns how long until the limit is full, for a "full in …" warning. It returns a time only when the limit fills
    /// before it resets (at `resetAt`) and within a day.
    func warning(_ key: String, resetAt: Date?, window: TimeInterval? = nil, now: Date = Date()) -> TimeInterval? {
        guard let resetAt, let eta = untilFull(key, resetAt: resetAt, window: window, now: now), eta > 0,
            eta < 24 * 3600,
            now.addingTimeInterval(eta) < resetAt
        else { return nil }
        return eta
    }

    /// True for a window longer than a day that resets within a day with over half of it unused, because what isn't
    /// used is lost at the reset. The 5-hour session never counts, because it comes back all day.
    static func unusedNearReset(percent: Double, resetAt: Date?, window: TimeInterval?, now: Date = Date()) -> Bool {
        guard let resetAt, let window, window > 86400 else { return false }
        let left = resetAt.timeIntervalSince(now)
        return left > 0 && left <= 86400 && percent < 50
    }

    /// Formats a duration as "5m", "1h 10m" or "2d 3h", rounded up to whole minutes, so a limit full in 30 seconds
    /// doesn't read as full in none.
    static func duration(_ t: TimeInterval) -> String { shortSpan((t / 60).rounded(.up) * 60, units: 2) }
}
