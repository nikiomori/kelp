import Core
import DesignKit
import Foundation
import TestSupport
import Testing

@testable import BuiltinAgents

private func line(_ kind: String, _ used: Double) -> UsageView.Line {
    UsageView.Line(label: kind, used: used, window: UsageGet.window(kind), kind: kind)
}

@MainActor @Test func eachLengthOfWindowGetsTheBarOfItsFullestLimit() {
    let cases: [(lines: [UsageView.Line], bars: [String])] = [
        // Week before 5 hours in the card, 5 hours first in the foot.
        ([line("week", 0.41), line("session", 0.83)], ["session", "week"]),
        // Claude on Max: two weeks, one bar.
        ([line("week", 0.84), line("week · Fable", 0.65)], ["week"]),
        // Antigravity: a week per model group, the fullest.
        ([line("Gemini week", 0.35), line("Claude week", 0.88), line("GPT week", 0.1)], ["Claude week"]),
        // Kimi: three windows, three bars.
        ([line("month", 0.3), line("session", 0.2), line("week", 0.47)], ["session", "week", "month"]),
        // Cursor's pools have no known window: they count as one long window.
        ([line("month", 0.23), line("Auto", 0.71), line("API", 0.05)], ["Auto"])
    ]
    for (lines, bars) in cases {
        #expect(LimitBars.bars(lines, agent: "a", shown: [], hidden: []).map(\.kind) == bars)
    }
}

@MainActor @Test func theEyeKeepsEveryLimitOfTheAgentAsItStoodAndNewOnesFollowTheDefault() {
    let lines = [line("week", 0.84), line("week · Fable", 0.65)]
    let next = LimitBars.toggled(lines[1], in: lines, agent: "claude", shown: [], hidden: ["codex/week"])
    #expect(next.shown == ["claude/week", "claude/week · Fable"] && next.hidden == ["codex/week"])
    // Fable overtaking the week doesn't take the week's bar away, as it would by the default.
    let later = [line("week", 0.84), line("week · Fable", 0.9), line("session", 0.1)]
    #expect(
        LimitBars.bars(later, agent: "claude", shown: next.shown, hidden: next.hidden).map(\.kind)
            == ["session", "week", "week · Fable"])
    // Hiding the week leaves Fable, and hiding that too leaves the fullest, never no bar.
    let hid = LimitBars.toggled(lines[0], in: lines, agent: "claude", shown: next.shown, hidden: next.hidden)
    #expect(
        LimitBars.bars(lines, agent: "claude", shown: hid.shown, hidden: hid.hidden).map(\.kind) == ["week · Fable"])
    #expect(LimitBars.bars(lines, agent: "claude", shown: [], hidden: hid.shown + hid.hidden).map(\.kind) == ["week"])
}

@MainActor @Test func aBarIsNamedByItsWindowOrItsModel() {
    #expect(LimitBars.tag("session") == "5h" && LimitBars.tag("week") == "wk" && LimitBars.tag("month") == "mo")
    #expect(LimitBars.tag("week · Fable") == "Fable" && LimitBars.tag("Gemini week") == "Gemini")
    #expect(LimitBars.tag("plan") == "Plan")
}

@MainActor @Test func hiddenAgentsLeaveTheFootButNeverAllOfThem() {
    func row(_ id: String, _ used: Double) -> UsageView.Row {
        UsageView.Row(id: id, name: id, fullName: id, lines: [line("week", used)])
    }
    let rows = [row("claude", 0.84), row("grok", 0.62), row("kimi", 0)]
    #expect(UsageView.visible(rows, hidden: ["grok"]).map(\.id) == ["claude"])
    #expect(UsageView.visible(rows, hidden: []).map(\.id) == ["claude", "grok"])   // 0% says nothing
    #expect(UsageView.visible(rows, hidden: ["claude", "grok"]).map(\.id) == ["claude", "grok"])   // the way back stays
}

/// The eye on an agent's last bar in the foot takes the agent out of the foot; any other eye only hides or shows its bar.
@Test func theEyeOnTheLastBarHidesTheAgent() {
    let grok = UsageView.Row(id: "grok", name: "Grok", fullName: "Grok", lines: [line("week", 1)])
    #expect(UsageView.hiding(line("week", 1), of: grok, bars: ["week"], hidden: ["codex"]) == ["codex", "grok"])
    let claude = UsageView.Row(id: "claude", name: "Claude", fullName: "Claude", lines: [line("week", 0.2)])
    #expect(UsageView.hiding(line("week", 0.2), of: claude, bars: ["session", "week"], hidden: []) == nil)
    #expect(UsageView.hiding(line("session", 0.1), of: claude, bars: ["week"], hidden: []) == nil)   // showing one
}

/// The pointer leaves the row for the card to click an eye: the card stays while it is on it, and goes after it leaves.
@MainActor @Test func theLimitCardStaysWhileThePointerIsOnIt() {
    let card = LimitCardHover()
    card.show("claude")
    card.hover("claude", false)   // off the row…
    card.card(true)   // …and onto the card, within the close's wait
    card.pending.flush()   // the close the row's leaving asked for: its wait is over
    #expect(card.shown == "claude")
    card.card(false)
    card.pending.flush()
    #expect(card.shown == nil)
}
