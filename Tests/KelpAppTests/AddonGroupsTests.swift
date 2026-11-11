import Core
import DesignKit
import Foundation
import Testing

@testable import BuiltinAgents

private func skill(_ name: String, _ source: Addon.Source, tokens: Int? = nil, off: Bool = false) -> Addon {
    Addon(kind: .skill, name: name, source: source, tokens: tokens, off: off)
}
private func server(
    _ name: String, _ source: Addon.Source, signIn: Bool = false, problem: String? = nil, tokens: Int? = nil
) -> Addon {
    Addon(
        kind: .server, name: name, source: source, problem: problem, signIn: signIn, tokens: tokens,
        key: "server:\(name)")
}
private func pluginSkill(_ plugin: String, _ name: String, tokens: Int? = nil) -> Addon {
    Addon(
        kind: .skill, name: "\(plugin):\(name)", source: .plugin, origin: plugin, loaded: true, tokens: tokens,
        key: "plugin:\(plugin)")
}

/// Problems first; the person's and the project's servers one by one, the rest folded, those waiting for a sign-in in
/// one group whoever brought them; skills by who brought them, This project and Yours open; instruction files last.
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
            .section(.needsLook, count: 2), .problem(broken), .unsigned([items[3]]),
            .section(.servers, count: 4), .item(broken, depth: 0),
            .group(account, count: 1, tokens: nil, open: false),
            .group(.init(kind: .server, source: .plugin), count: 1, tokens: nil, open: false),
            .group(.init(kind: .server, source: nil), count: 1, tokens: nil, open: false),
            .section(.skills, count: 3), .group(yours, count: 1, tokens: nil, open: true),
            .item(items[4], depth: 1), .group(kelp, count: 1, tokens: nil, open: false),
            .group(.init(kind: .skill, source: .agent), count: 1, tokens: nil, open: false),
            .section(.instructions, count: 1), .item(items[7], depth: 0)
        ])
    // A click folds an open group and opens a folded one.
    let toggled = AddonGroups.lines(items, toggled: [yours, kelp])
    #expect(toggled.contains(.item(items[5], depth: 1)))
    #expect(!toggled.contains(.item(items[4], depth: 1)))
    #expect(AddonGroups.lines([], toggled: []).isEmpty)
}

/// The plugins are one Plugins group; in it a line per plugin (heaviest first) with its switch, unfolding to its
/// skills. One that's off (nothing of it loaded) is a line with nothing to unfold.
@Test func addonPluginsAreOneGroupOfPluginLines() {
    let prep = pluginSkill("sales", "call-prep", tokens: 300), brief = pluginSkill("sales", "brief", tokens: 900)
    let chart = pluginSkill("data", "chart", tokens: 2000)
    let off = Addon(kind: .plugin, name: "legal", source: .plugin, key: "plugin:legal", off: true)
    let items = [prep, brief, chart, off]
    let plugins = AddonGroup(kind: .skill, source: .plugin)
    let sales = AddonGroup(kind: .skill, source: .plugin, plugin: "sales")
    let data = AddonGroup(kind: .skill, source: .plugin, plugin: "data")
    let legal = AddonGroup(kind: .skill, source: .plugin, plugin: "legal")
    #expect(
        AddonGroups.lines(items, toggled: []) == [
            .section(.skills, count: 3), .group(plugins, count: 3, tokens: 3200, open: false)
        ])
    #expect(
        AddonGroups.lines(items, toggled: [plugins, sales]) == [
            .section(.skills, count: 3), .group(plugins, count: 3, tokens: 3200, open: true),
            .group(data, count: 1, tokens: 2000, open: false), .group(sales, count: 2, tokens: 1200, open: true),
            .item(brief, depth: 2), .item(prep, depth: 2), .group(legal, count: 0, tokens: nil, open: false)
        ])
    #expect(sales.key == "plugin:sales" && sales.title == "sales" && plugins.title == "Plugins")
    #expect(AddonGroups.isOff(legal, items) && !AddonGroups.isOff(sales, items))
    var withId = prep
    withId.plugin = "sales@synced"
    withId.path = "/p/sales/skills/call-prep/SKILL.md"
    #expect(AddonGroups.pluginId("sales", [brief, withId]) == "sales@synced")
    #expect(AddonGroups.pluginFolder("sales", [withId]) == "/p/sales" && AddonGroups.pluginFolder("x", [withId]) == nil)
}

/// By weight: the heaviest first, unknown last, then by name; by name when asked. What's off hides when asked.
@Test func addonSortAndShowOff() {
    let a = skill("a", .yours, tokens: 10), b = skill("b", .yours, tokens: 500), c = skill("c", .yours)
    let d = skill("d", .yours, off: true)
    let yours = AddonGroup(kind: .skill, source: .yours)
    #expect(
        AddonGroups.lines([a, b, c, d], toggled: []) == [
            .section(.skills, count: 4), .group(yours, count: 4, tokens: 510, open: true),
            .item(b, depth: 1), .item(a, depth: 1), .item(c, depth: 1), .item(d, depth: 1)
        ])
    let byName = AddonGroups.lines([a, b, c, d], toggled: [], view: AddonView(byName: true, showOff: false))
    #expect(
        byName == [
            .section(.skills, count: 3), .group(yours, count: 3, tokens: 510, open: true),
            .item(a, depth: 1), .item(b, depth: 1), .item(c, depth: 1)
        ])
}

/// The filter narrows every section to the names it matches, opens the groups with a match, and drops the rest.
@Test func addonFilterNarrowsAndUnfolds() {
    let items = [
        skill("pdf-tools", .agent), skill("tabbit", .yours), server("pdfserver", .account),
        pluginSkill("data", "make-pdf"), Addon(kind: .instructions, name: "CLAUDE.md", source: .project)
    ]
    let lines = AddonGroups.lines(items, toggled: [], view: AddonView(filter: "PDF"))
    let plugins = AddonGroup(kind: .skill, source: .plugin)
    let data = AddonGroup(kind: .skill, source: .plugin, plugin: "data")
    #expect(
        lines == [
            .section(.servers, count: 1),
            .group(.init(kind: .server, source: .account), count: 1, tokens: nil, open: true),
            .item(items[2], depth: 1),
            .section(.skills, count: 2), .group(plugins, count: 1, tokens: nil, open: true),
            .group(data, count: 1, tokens: nil, open: true), .item(items[3], depth: 2),
            .group(.init(kind: .skill, source: .agent), count: 1, tokens: nil, open: true), .item(items[0], depth: 1)
        ])
    #expect(AddonGroups.lines(items, toggled: [], view: AddonView(filter: "nothing")).isEmpty)
}

/// The servers waiting for a sign-in that are on are one line in Needs a Look, with what they cost; none when all are
/// off.
@Test func addonUnsignedLine() {
    let one = server("figma", .plugin, signIn: true, tokens: 1200),
        two = server("notion", .account, signIn: true, tokens: 700)
    var offOne = one
    offOne.off = true
    #expect(AddonGroups.unsigned([one, two, server("x", .yours)]) == [one, two])
    #expect(
        AddonGroups.unsignedText([one, two]) == ("2 servers aren’t signed in", "Idle, 1.9k tokens each chat"))
    #expect(AddonGroups.unsignedText([server("y", .yours)]).title == "1 server isn’t signed in")
    var offTwo = two
    offTwo.off = true
    #expect(
        !AddonGroups.lines([offOne, offTwo], toggled: []).contains { if case .unsigned = $0 { true } else { false } })
}

/// The weight: a headline of the whole, its parts biggest first; the counts while weights aren't known.
@Test func addonWeightParts() {
    let items = [
        skill("a", .yours, tokens: 2500), pluginSkill("sales", "x", tokens: 9600), server("c", .yours, tokens: 5700),
        Addon(kind: .instructions, name: "CLAUDE.md", source: .project, tokens: 20_600), server("d", .yours)
    ]
    #expect(
        AddonGroups.weight(items) == [
            .init(part: .instructions, tokens: 20_600), .init(part: .plugins, tokens: 9600),
            .init(part: .servers, tokens: 5700), .init(part: .other, tokens: 2500)
        ])
    #expect(AddonGroups.headline(items, chat: true) == "38.4k tokens before the first word")
    #expect(AddonGroups.headline(items, chat: false) == "2 skills · 2 servers")
    #expect(AddonGroups.weight([server("d", .yours)]).isEmpty)
    #expect(AddonGroups.countAndTokens(7, 480) == "7 · 0.5k" && AddonGroups.countAndTokens(7, nil) == "7")
    #expect(AddonGroups.countAndTokens(3, 2300) == "3 · 2.3k" && AddonGroups.countAndTokens(1, 980) == "1 · 1k")
    #expect(shortTokens(435) == "435" && shortTokens(5000) == "5k" && shortTokens(1240) == "1.2k")
}

@Test func addonTextsAndFolders() {
    let tip = Addon(
        kind: .skill, name: "x", source: .yours, about: "Does x", origin: "~/.agents/skills",
        copies: ["~/.claude/skills"])
    #expect(AddonGroups.tip(tip) == "Does x\n~/.agents/skills\nAlso in ~/.claude/skills")
    let fixed = Addon(kind: .skill, name: "x", source: .yours, fixed: ["cursor"])
    #expect(AddonGroups.tip(fixed) { $0.capitalized } == "Always on in Cursor: no switch for one chat there")
    var waiting = pluginSkill("sales", "x")
    #expect(!AddonGroups.waits(waiting))
    waiting.off = true
    #expect(AddonGroups.waits(waiting))
    #expect(AddonGroups.footNote(gone: []) == "Changes reach new chats.")
    #expect(
        AddonGroups.footNote(gone: ["pencil", "tabbit", "x"]) == "This chat still has pencil and 2 more, removed since."
    )
    // The name first: of what's beside it, as much as fits, in order.
    #expect(AddonGroups.fitting([40, 60, 80], in: 110) == 2 && AddonGroups.fitting([40, 60], in: 30) == 0)
    #expect(AddonGroups.fitting([40], in: -20) == 0 && AddonGroups.fitting([], in: 100) == 0)
    var inProject = skill("p", .project)
    inProject.path = "/repo/.claude/skills/p/SKILL.md"
    #expect(
        AddonGroups.skillFolders(home: "/h", project: "/repo", items: [inProject]) == [
            "/h/.agents/skills", "/h/.claude/skills", "/repo/.claude/skills"
        ])
    #expect(AddonGroups.serverName(server("ctx", .yours)) == "ctx")
}

/// A problem switched off for the project is dealt with: Needs a Look lets it go, its own section keeps it.
@Test func aProblemThatsOffLeavesNeedsALook() {
    var broken = Addon(kind: .server, name: "definite", source: .plugin, problem: "Not found", key: "server:d")
    #expect(AddonGroups.lines([broken], toggled: []).contains(.problem(broken)))
    broken.off = true
    let lines = AddonGroups.lines([broken], toggled: [])
    #expect(!lines.contains(.problem(broken)) && !lines.contains { $0 == .section(.needsLook, count: 1) })
}
