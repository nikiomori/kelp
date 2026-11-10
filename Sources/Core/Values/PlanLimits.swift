import Foundation

/// A reset as the agents print it: "in 1h 30m", "in 3d", "3pm", "7:40am", "Oct 20 at 5am", "Oct 30, 2026 3:40 PM", "November 7, 19:36"; nil for anything else.
public enum ResetTime {
    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        read(text, now: now, calendar: calendar)?.date
    }

    /// One way of saying it, whichever agent said it (each CLI has its own): the time within half a day, the weekday and
    /// time within the week, else the date and time. Text it can't read stays as the agent wrote it.
    public static func shown(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let reading = read(text, now: now, calendar: calendar) else { return text }
        return reading.timed
            ? shown(reading.date, now: now) : reading.date.formatted(.dateTime.month(.abbreviated).day())
    }

    public static func shown(_ date: Date, now: Date = Date()) -> String {
        let left = date.timeIntervalSince(now)
        return left < 12 * 3600
            ? date.formatted(date: .omitted, time: .shortened)
            : left < 6 * 86400
                ? date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
                : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// `timed`: it said a time of day as well as a date.
    private static func read(_ text: String, now: Date, calendar: Calendar) -> (date: Date, timed: Bool)? {
        let lowered = text.trimmingCharacters(in: .whitespaces).lowercased()
        if lowered.hasPrefix("in ") {
            var secs = 0.0
            for match in lowered.matches(of: /(\d+)\s*(d|h|m)\b/) {
                secs += (Double(match.1) ?? 0) * (match.2 == "d" ? 86400 : match.2 == "h" ? 3600 : 60)
            }
            return secs > 0 ? (now.addingTimeInterval(secs), true) : nil
        }
        let clock =
            #/
            (?: (jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec) [a-z]* \s+ (\d{1,2}) (?: ,\s+\d{4}\s+ | ,\s+ | \s+at\s+ | $ ) )?
            (?: (\d{1,2}) (?: :(\d{2}) )? \s* (am|pm)? )?
            /#
        // a date, a time, or both
        guard let match = lowered.wholeMatch(of: clock), match.1 != nil || match.3 != nil else { return nil }
        var hour = 0
        if let clockHour = match.3.flatMap({ Int($0) }) {
            if match.5 == nil {   // "19:36": a 24-hour clock has its minutes
                guard match.4 != nil, (0...23).contains(clockHour) else { return nil }
                hour = clockHour
            } else {
                guard (1...12).contains(clockHour) else { return nil }
                hour = clockHour % 12 + (match.5 == "pm" ? 12 : 0)
            }
        }
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = match.4.flatMap { Int($0) } ?? 0
        components.second = 0
        if let mon = match.1, let day = match.2.flatMap({ Int($0) }),
            let month = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].firstIndex(
                of: String(mon))
        {
            components.month = month + 1
            components.day = day
            guard let date = calendar.date(from: components) else { return nil }
            return (date >= now ? date : calendar.date(byAdding: .year, value: 1, to: date)).map {
                ($0, match.3 != nil)
            }
        }
        guard let date = calendar.date(from: components) else { return nil }
        return (date >= now ? date : calendar.date(byAdding: .day, value: 1, to: date)).map { ($0, true) }
    }
}

extension UsageGet {
    /// A window's length by its kind; a month is taken as 30 days (Codex's free plan says 43 200 minutes itself).
    public static func window(_ kind: String) -> TimeInterval? {
        let lowered = kind.lowercased()
        return kind == "session"
            ? 5 * 3600 : lowered.contains("week") ? 7 * 86400 : lowered.contains("month") ? 30 * 86400 : nil
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
        if let latest = codex.first {
            let at = { (seconds: Double?) in seconds.map { Date(timeIntervalSince1970: $0) } },
                read = Date(timeIntervalSince1970: latest.observedAt)
            for (percent, reset, minutes, primary) in [
                (latest.primaryUsedPercent, latest.primaryResetsAt, latest.primaryWindowMinutes, true),
                (latest.secondaryUsedPercent, latest.secondaryResetsAt, latest.secondaryWindowMinutes, false)
            ] {
                guard let percent else { continue }
                let kind = UsageGet.Codex.kind(minutes: minutes, primary: primary)
                out.append(
                    Reading(
                        agent: "codex", limit: .init(kind: kind, percent: percent, resets: nil), resetAt: at(reset),
                        window: minutes.map { $0 * 60 } ?? UsageGet.window(kind), readAt: read))
            }
        }
        return out
    }

    /// The readings that say something about now: not the ones the sidebar dims, read more than half an hour ago.
    public func fresh(now: Date = Date()) -> [Reading] {
        readings(now: now).filter { $0.readAt.map { now.timeIntervalSince($0) <= 1800 } ?? true }
    }
}
