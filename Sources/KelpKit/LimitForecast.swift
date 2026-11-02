import Foundation
import Core

/// When a plan limit will be full at the pace it's filling, and whether that comes before it resets. Readings arrive every
/// ten minutes or so; the pace is the rise over the last two hours (a window that reset starts again).
struct LimitForecast {
    private var samples: [String: [(at: Date, percent: Double)]] = [:]
    static let span: TimeInterval = 2 * 3600

    static func key(_ agent: String, _ kind: String) -> String { agent + "|" + kind }

    mutating func record(_ u: UsageGet.Result, now: Date = Date()) {
        for (agent, l, _) in LimitAlerts.readings(u, now: now) {
            let k = Self.key(agent, l.kind)
            var s = samples[k] ?? []
            if let last = s.last {
                if l.percent < last.percent { s = [] }                       // its window reset
                else if now.timeIntervalSince(last.at) < 120 { continue }    // one push per read is enough
            }
            s.append((now, l.percent))
            samples[k] = s.filter { now.timeIntervalSince($0.at) <= Self.span }
        }
    }

    /// Seconds until it's full at the pace of the last two hours; nil when it isn't rising or there's too little to tell.
    func untilFull(_ key: String, now: Date = Date()) -> TimeInterval? {
        guard let s = samples[key], let first = s.first, let last = s.last, last.at.timeIntervalSince(first.at) >= 480 else { return nil }
        let rate = (last.percent - first.percent) / now.timeIntervalSince(first.at)   // points a second, idle time since counted
        guard rate > 0, last.percent < 100 else { return nil }
        return (100 - last.percent) / rate - now.timeIntervalSince(last.at)
    }

    /// The time to say "full in …" for: it fills before it resets (at `resetAt`), within a day.
    func warning(_ key: String, resetAt: Date?, now: Date = Date()) -> TimeInterval? {
        guard let resetAt, let eta = untilFull(key, now: now), eta > 0, eta < 24 * 3600, now.addingTimeInterval(eta) < resetAt else { return nil }
        return eta
    }

    static func duration(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded(.up))
        return m < 60 ? String(localized: "\(m) min") : m < 36 * 60 ? String(localized: "\(m / 60) h \(m % 60) min") : String(localized: "\(m / 1440) days")
    }
}

/// A reset as the agents print it: "in 1h 30m", "in 3d", "3pm", "7:40am", "Oct 20 at 5am", "Oct 30, 2026 3:40 PM", "November 7, 19:36"; nil for anything else.
enum ResetTime {
    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        read(text, now: now, calendar: calendar)?.date
    }

    /// One way of saying it, whichever agent said it (each CLI has its own): the time within half a day, the weekday and
    /// time within the week, else the date and time. Text it can't read stays as the agent wrote it.
    static func shown(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let r = read(text, now: now, calendar: calendar) else { return text }
        return r.timed ? shown(r.date, now: now) : r.date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func shown(_ d: Date, now: Date = Date()) -> String {
        let left = d.timeIntervalSince(now)
        return left < 12 * 3600 ? d.formatted(date: .omitted, time: .shortened)
            : left < 6 * 86400 ? d.formatted(.dateTime.weekday(.wide).hour().minute())
            : d.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// `timed`: it said a time of day as well as a date.
    private static func read(_ text: String, now: Date, calendar: Calendar) -> (date: Date, timed: Bool)? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("in ") {
            var secs = 0.0
            for m in t.matches(of: /(\d+)\s*(d|h|m)\b/) {
                secs += (Double(m.1) ?? 0) * (m.2 == "d" ? 86400 : m.2 == "h" ? 3600 : 60)
            }
            return secs > 0 ? (now.addingTimeInterval(secs), true) : nil
        }
        let clock = #/
            (?: (jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec) [a-z]* \s+ (\d{1,2}) (?: ,\s+\d{4}\s+ | ,\s+ | \s+at\s+ | $ ) )?
            (?: (\d{1,2}) (?: :(\d{2}) )? \s* (am|pm)? )?
            /#
        guard let m = t.wholeMatch(of: clock), m.1 != nil || m.3 != nil else { return nil }   // a date, a time, or both
        var hour = 0
        if let h = m.3.flatMap({ Int($0) }) {
            if m.5 == nil {   // "19:36": a 24-hour clock has its minutes
                guard m.4 != nil, (0...23).contains(h) else { return nil }
                hour = h
            } else {
                guard (1...12).contains(h) else { return nil }
                hour = h % 12 + (m.5 == "pm" ? 12 : 0)
            }
        }
        var c = calendar.dateComponents([.year, .month, .day], from: now)
        c.hour = hour
        c.minute = m.4.flatMap { Int($0) } ?? 0
        c.second = 0
        if let mon = m.1, let day = m.2.flatMap({ Int($0) }),
           let i = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].firstIndex(of: String(mon)) {
            c.month = i + 1
            c.day = day
            guard let d = calendar.date(from: c) else { return nil }
            return (d >= now ? d : calendar.date(byAdding: .year, value: 1, to: d)).map { ($0, m.3 != nil) }
        }
        guard let d = calendar.date(from: c) else { return nil }
        return (d >= now ? d : calendar.date(byAdding: .day, value: 1, to: d)).map { ($0, true) }
    }
}
