import Foundation

/// A reset as the agents print it: "in 1h 30m", "in 3d", "3pm", "7:40am", "Oct 20 at 5am", "Oct 30, 2026 3:40 PM", "November 7, 19:36"; nil for anything else.
public enum ResetTime {
    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        read(text, now: now, calendar: calendar)?.date
    }

    /// One way of saying it, whichever agent said it (each CLI has its own): the time within half a day, the weekday and
    /// time within the week, else the date and time. Text it can't read stays as the agent wrote it.
    public static func shown(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let r = read(text, now: now, calendar: calendar) else { return text }
        return r.timed ? shown(r.date, now: now) : r.date.formatted(.dateTime.month(.abbreviated).day())
    }

    public static func shown(_ d: Date, now: Date = Date()) -> String {
        let left = d.timeIntervalSince(now)
        return left < 12 * 3600
            ? d.formatted(date: .omitted, time: .shortened)
            : left < 6 * 86400
                ? d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
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
        let clock =
            #/
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
            let i = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].firstIndex(
                of: String(mon))
        {
            c.month = i + 1
            c.day = day
            guard let d = calendar.date(from: c) else { return nil }
            return (d >= now ? d : calendar.date(byAdding: .year, value: 1, to: d)).map { ($0, m.3 != nil) }
        }
        guard let d = calendar.date(from: c) else { return nil }
        return (d >= now ? d : calendar.date(byAdding: .day, value: 1, to: d)).map { ($0, true) }
    }
}

extension UsageGet {
    /// A window's length by its kind; a month is taken as 30 days (Codex's free plan says 43 200 minutes itself).
    public static func window(_ kind: String) -> TimeInterval? {
        let k = kind.lowercased()
        return kind == "session" ? 5 * 3600 : k.contains("week") ? 7 * 86400 : k.contains("month") ? 30 * 86400 : nil
    }
}

extension UsageGet.Result {
    /// One plan limit, from whichever source has it: when it resets, if that can be told, how long its window is, and
    /// when the agent last showed it (nil: not known).
    public struct Reading: Sendable, Equatable {
        public var agent: String, limit: UsageGet.Limit, resetAt: Date?, window: TimeInterval?, readAt: Date?
    }

    /// Every limit the agents report, as the sidebar's rings show them: the /usage screens', Claude's printed percentages
    /// when its screen wasn't read, Codex's own log.
    public func readings(now: Date = Date()) -> [Reading] {
        let readAt = { (agent: String) in plansReadAt?[agent].map { Date(timeIntervalSince1970: $0) } }
        var out: [Reading] = []
        func add(_ agent: String, _ ls: [UsageGet.Limit]) {
            // "in 4h" counts from when the screen said it, not from now.
            let at = readAt(agent)
            out += ls.map {
                Reading(
                    agent: agent, limit: $0, resetAt: $0.resets.flatMap { ResetTime.parse($0, now: at ?? now) },
                    window: UsageGet.window($0.kind), readAt: at)
            }
        }
        for (agent, ls) in plans ?? [:] where agent != "claude" { add(agent, ls) }
        add("claude", plans?["claude"] ?? claudeLimits ?? [])
        if let x = codex.first {
            let at = { (t: Double?) in t.map { Date(timeIntervalSince1970: $0) } },
                read = Date(timeIntervalSince1970: x.observedAt)
            for (p, reset, minutes, primary) in [
                (x.primaryUsedPercent, x.primaryResetsAt, x.primaryWindowMinutes, true),
                (x.secondaryUsedPercent, x.secondaryResetsAt, x.secondaryWindowMinutes, false)
            ] {
                guard let p else { continue }
                let kind = UsageGet.Codex.kind(minutes: minutes, primary: primary)
                out.append(
                    Reading(
                        agent: "codex", limit: .init(kind: kind, percent: p, resets: nil), resetAt: at(reset),
                        window: minutes.map { $0 * 60 } ?? UsageGet.window(kind), readAt: read))
            }
        }
        return out
    }
}
