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
