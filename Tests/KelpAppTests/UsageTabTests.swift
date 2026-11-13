import Core
import Foundation
import Testing

@testable import BuiltinAgents

@MainActor @Test func usageNamesClaudeModelsAsClaudeCodeDoes() {
    #expect(UsageReportView.model("claude-opus-5-5") == "Opus 5.5")
    #expect(UsageReportView.model("claude-haiku-4-5-20251001") == "Haiku 4.5")
    #expect(UsageReportView.model("claude-opus-5") == "Opus 5")
    #expect(UsageReportView.model("deepseek/deepseek-v4.1-flash-1017") == "deepseek/deepseek-v4.1-flash-1017")
}

@Test func monthsSumTheirDaysAndEndWithThisOne() throws {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = try #require(TimeZone(identifier: "UTC"))
    let day = { (y: Int, m: Int, d: Int) in try #require(cal.date(from: DateComponents(year: y, month: m, day: d))) }
    let days = [
        try day(2026, 10, 5): 10.0, try day(2026, 10, 20): 5, try day(2026, 11, 1): 3, try day(2025, 11, 10): 99
    ]
    let months = MonthBars.months(days, now: try day(2026, 11, 13), calendar: cal)
    let december = try day(2025, 12, 1)
    #expect(months.count == 12 && months.first?.start == december)
    #expect(months.last?.value == 3 && months[10].value == 15 && !months.contains { $0.value == 99 })   // a year ago is out
}

@Test func usageComparesTheSpanWithTheOneBefore() {
    #expect(
        UsageReportView.change(12073, before: 5058, days: 30) == "at API prices · +139% on the 30 days before ($5,058)")
    #expect(UsageReportView.change(50, before: 100, days: 7) == "at API prices · -50% on the 7 days before ($100)")
    #expect(UsageReportView.change(5, before: 0, days: 7) == "at API prices · nothing the 7 days before")
    #expect(UsageReportView.change(5, before: nil, days: 371) == "at API prices")
    #expect(CostSplit.share(0.5, of: 100) == "<1%" && CostSplit.share(57, of: 100) == "57%")
}

/// A limit says when it runs out at its pace: used up, full before it resets, or where it ends at the reset.
@MainActor @Test func planOutlookSaysWhenALimitRunsOut() {
    let now = Date(timeIntervalSince1970: 1_800_000_000), week: TimeInterval = 7 * 86400
    var forecast = LimitForecast()
    forecast.record(
        UsageGet.Result(
            claude: [], codex: [],
            plans: [
                "grok": [UsageGet.Limit(kind: "week", percent: 47, resets: "in 1d 8h")],
                "claude": [UsageGet.Limit(kind: "week", percent: 84, resets: "in 3d 18h")]
            ],
            plansReadAt: ["grok": now.timeIntervalSince1970, "claude": now.timeIntervalSince1970]), now: now)
    // 47 % with 136 of the week's 168 hours gone ends near 58 % at the reset 32 hours on.
    let grok = UsageView.Line(
        label: "Week", used: 0.47, resets: "Sat", resetAt: now.addingTimeInterval(32 * 3600), window: week, kind: "week"
    )
    #expect(
        PlanOutlook.of(grok, agent: "grok", stale: false, forecast: forecast, now: now)
            == .atReset(47 + 47.0 / 136 * 32))
    // 84 % in 78 hours fills about 15 hours on, days before the reset.
    let claude = UsageView.Line(
        label: "Week", used: 0.84, resets: "Tue", resetAt: now.addingTimeInterval(90 * 3600), window: week, kind: "week"
    )
    guard
        case .fullBefore(let full) = PlanOutlook.of(claude, agent: "claude", stale: false, forecast: forecast, now: now)
    else {
        Issue.record("not full before its reset")
        return
    }
    #expect(abs(full.timeIntervalSince(now) - 16 / (84.0 / 78) * 3600) < 60)
    var usedUp = claude
    usedUp.used = 1
    #expect(
        PlanOutlook.of(usedUp, agent: "claude", stale: false, forecast: forecast, now: now)
            == .usedUp(back: claude.resetAt))
    #expect(PlanOutlook.of(claude, agent: "claude", stale: true, forecast: forecast, now: now) == .unknown)
    #expect(PlanOutlook.usedUp(back: nil).text(usedUp, now: now) == "Used up")
}
