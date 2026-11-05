import Foundation
import Testing
import Core
@testable import KelpKit

@Test func codexWindowsAreNamedByTheirLength() {
    #expect(UsageGet.Codex.kind(minutes: 300, primary: true) == "session")
    #expect(UsageGet.Codex.kind(minutes: 10080, primary: false) == "week")
    #expect(UsageGet.Codex.kind(minutes: 43200, primary: true) == "month")   // the free plan: not 5 hours
    #expect(UsageGet.Codex.kind(minutes: nil, primary: true) == "session")
    #expect(UsageGet.Codex.kind(minutes: nil, primary: false) == "week")
}

@Test func theTickIsTheShareOfTheWindowGoneAndTheTimeOnlyWithin12Hours() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let day = 86400.0
    // Codex's month with 19 days left: 11 of 30 gone.
    let month = UsageView.Line(label: "Month", used: 0.35, resets: "Nov 23", resetAt: now + 19 * day, window: 30 * day)
    #expect(abs((month.pace(now: now) ?? 0) - 11.0 / 30) < 0.0001)
    #expect(month.soon(now: now) == nil)
    // Claude's 5 hours resetting in 3: 40 % gone, and the time shows.
    let session = UsageView.Line(label: "5 hours", used: 0.08, resets: "3:40 PM", resetAt: now + 3 * 3600, window: UsageView.window("session"))
    #expect(abs((session.pace(now: now) ?? 0) - 0.4) < 0.0001)
    #expect(session.soon(now: now) == "3:40 PM")
    // Without a reset, a known window or one that already passed: no tick.
    #expect(UsageView.Line(label: "Week", used: 0.1, resets: nil, resetAt: nil, window: 7 * day).pace(now: now) == nil)
    #expect(UsageView.Line(label: "Week", used: 0.1, resets: "x", resetAt: now + day, window: nil).pace(now: now) == nil)
    #expect(UsageView.Line(label: "Week", used: 0.1, resets: "x", resetAt: now - 60, window: 7 * day).pace(now: now) == nil)
    #expect(UsageView.window("week · Fable") == 7 * day && UsageView.window("Gemini week") == 7 * day && UsageView.window("daily") == nil)
}

@Test func limitForecastTellsFromOneReadingByTheWindowsAverage() {
    let now = Date(timeIntervalSince1970: 1_800_000_000), week = 7 * 86400.0
    let key = LimitForecast.key("claude", "week")
    var f = LimitForecast()
    f.record(.init(claude: [], codex: [], plans: ["claude": [.init(kind: "week", percent: 60, resets: nil)]]), now: now)
    // 3 of 7 days gone at 60 %: 20 points a day, full in 2 days, before the reset in 4.
    let reset = now.addingTimeInterval(4 * 86400)
    #expect(abs((f.untilFull(key, resetAt: reset, window: week, now: now) ?? 0) - 2 * 86400) < 1)
    #expect(abs((f.atReset(key, resetAt: reset, window: week, now: now) ?? 0) - 140) < 0.001)
    #expect(f.warning(key, resetAt: reset, window: week, now: now) == nil)   // more than a day away
    #expect(f.untilFull(key, resetAt: now.addingTimeInterval(week - 600), window: week, now: now) == nil)   // the window just began
    #expect(f.untilFull(key, resetAt: reset, now: now) == nil)              // no window, no average
}

@Test func onlyLongWindowsWithMostLeftCountAsUnusedAtTheReset() {
    let now = Date(timeIntervalSince1970: 1_800_000_000), week = 7 * 86400.0
    #expect(LimitForecast.unusedNearReset(percent: 30, resetAt: now.addingTimeInterval(18 * 3600), window: week, now: now))
    #expect(!LimitForecast.unusedNearReset(percent: 60, resetAt: now.addingTimeInterval(18 * 3600), window: week, now: now))   // most used
    #expect(!LimitForecast.unusedNearReset(percent: 30, resetAt: now.addingTimeInterval(30 * 3600), window: week, now: now))   // not yet
    #expect(!LimitForecast.unusedNearReset(percent: 10, resetAt: now.addingTimeInterval(3600), window: 5 * 3600, now: now))     // a session
    #expect(!LimitForecast.unusedNearReset(percent: 10, resetAt: nil, window: week, now: now))
}
