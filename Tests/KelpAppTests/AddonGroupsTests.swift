import Core
import Foundation
import Testing

@testable import BuiltinAgents

private func skill(_ name: String, _ source: Addon.Source, tokens: Int? = nil) -> Addon {
    Addon(kind: .skill, name: name, source: source, tokens: tokens)
}
private func server(_ name: String, _ source: Addon.Source, signIn: Bool = false, problem: String? = nil) -> Addon {
    Addon(kind: .server, name: name, source: source, problem: problem, signIn: signIn)
}

/// Problems first; the person's and the project's servers one by one, the rest folded, those waiting for a sign-in in
/// one group whoever brought them; skills by who brought them, Yours and This project open; instruction files last.
@Test func addonLinesGroupAndFold() {
    let broken = server("pencil", .yours, problem: "Doesn’t start")
    let items = [
        broken, server("context7", .plugin), server("gmail", .account), server("linear", .account, signIn: true),
        skill("tabbit", .yours), skill("guide", .kelp), skill("pdf", .agent),
        Addon(kind: .instructions, name: "CLAUDE.md", source: .project)
    ]
    let lines = AddonGroups.lines(items, toggled: [])
    let account = AddonGroup(kind: .server, source: .account), kelp = AddonGroup(kind: .skill, source: .kelp)
    let yours = AddonGroup(kind: .skill, source: .yours)
    #expect(
        lines == [
            .section(.needsLook, count: 1), .problem(broken),
            .section(.servers, count: 4), .item(broken, nested: false),
            .group(account, count: 1, open: false),
            .group(.init(kind: .server, source: .plugin), count: 1, open: false),
            .group(.init(kind: .server, source: nil), count: 1, open: false),
            .section(.skills, count: 3), .group(kelp, count: 1, open: false), .group(yours, count: 1, open: true),
            .item(items[4], nested: true), .group(.init(kind: .skill, source: .agent), count: 1, open: false),
            .section(.instructions, count: 1), .item(items[7], nested: false)
        ])
    // A click folds an open group and opens a folded one.
    let toggled = AddonGroups.lines(items, toggled: [yours, kelp])
    #expect(toggled.contains(.item(items[5], nested: true)))
    #expect(!toggled.contains(.item(items[4], nested: true)))
    #expect(AddonGroups.lines([], toggled: []).isEmpty)
}

@Test func addonSummaryCountsAndTokens() {
    let plain = [skill("a", .yours), skill("b", .yours), server("c", .yours), server("d", .yours)]
    #expect(AddonGroups.summary(plain) == "2 skills · 2 servers")
    let costly = [skill("a", .yours, tokens: 7000), skill("b", .kelp, tokens: 480), server("c", .yours)]
    #expect(AddonGroups.summary(costly + [server("d", .yours)]) == "2 skills · 2 servers · ~7.5k tokens at start")
    #expect(AddonGroups.tokens(95) == "95 tok")
    #expect(AddonGroups.tokens(1240) == "1.2k tok")
    let tip = Addon(
        kind: .skill, name: "x", source: .yours, about: "Does x", origin: "~/.agents/skills",
        copies: ["~/.claude/skills"])
    #expect(AddonGroups.tip(tip) == "Does x\n~/.agents/skills\nAlso in ~/.claude/skills")
}

/// A plugin is a group of its own with the switch on its line; one that's off (nothing of it loaded) is a bare line.
/// A row waits for a restart when its switch and what the chat loaded disagree.
@Test func addonPluginsAreGroupsWithASwitch() {
    let prep = Addon(
        kind: .skill, name: "sales:call-prep", source: .plugin, origin: "sales", loaded: true, key: "plugin:sales")
    let off = Addon(kind: .plugin, name: "legal", source: .plugin, key: "plugin:legal", off: true)
    let sales = AddonGroup(kind: .skill, source: .plugin, plugin: "sales")
    let legal = AddonGroup(kind: .skill, source: .plugin, plugin: "legal")
    #expect(
        AddonGroups.lines([prep, off], toggled: []) == [
            .section(.skills, count: 1), .group(legal, count: 0, open: false), .group(sales, count: 1, open: false)
        ])
    #expect(sales.key == "plugin:sales" && sales.title == "sales")
    #expect(AddonGroups.isOff(legal, [prep, off]) && !AddonGroups.isOff(sales, [prep, off]))
    var turnedOff = prep
    turnedOff.off = true
    #expect(AddonGroups.waits(turnedOff) && !AddonGroups.waits(prep) && !AddonGroups.waits(off))
    let fixed = Addon(kind: .skill, name: "x", source: .yours, fixed: ["cursor"])
    #expect(AddonGroups.tip(fixed) { $0.capitalized } == "Always on in Cursor: no switch for one chat there")
}
