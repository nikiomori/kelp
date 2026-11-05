import AppKit
import Testing
@testable import KelpApp
@testable import KelpKit
@testable import BuiltinAgents

@MainActor @Test func aPickerListsAValueFromOutsideItsChoices() {
    #expect(SettingRow.shown(["block", "bar"], "bar") == ["block", "bar"])
    #expect(SettingRow.shown(["block", "bar"], "beam") == ["block", "bar", "beam"])
    #expect(SettingRow.shown(["block", "bar"], "") == ["block", "bar"])
}

@Test func aNumberWithARangeStaysInIt() {
    let size = SettingSpec(key: "k", title: "T", type: "number", range: [8, 40])
    #expect(size.clamped(-3) == 8 && size.clamped(13) == 13 && size.clamped(200) == 40)
    #expect(SettingSpec(key: "k", title: "T", type: "number").clamped(-3) == -3)
    #expect(SettingSpec(key: "k", title: "T", type: "number", range: [8]).bounds == nil)   // from an extension.json: ignored
}

@MainActor @Test func searchFindsGroupsSectionsAndWhatAPageDeclares() {
    func row(_ key: String, _ title: String, group: String? = nil) -> SettingSpec { SettingSpec(key: key, title: title, type: "boolean", group: group) }
    let sections = [
        SettingsSection(id: "agents", title: "Agents", icon: "", specs: [row("a.one", "Keep Mac awake"), row("a.two", "When it fails", group: "Notifications"),
                                                                         row("a.three", "When it waits", group: "Notifications")], keywords: ["Accounts"]),
        SettingsSection(id: "links", title: "Integrations", icon: "", specs: [], keywords: ["GitHub", "Linear"])
    ]
    let group = SettingsSearch.find("notifications", in: sections)
    #expect(group.map(\.title) == ["Agents › Notifications"] && group.first?.specs.count == 2)   // one card, the two rows
    #expect(SettingsSearch.find("github", in: sections).map(\.screens) == [["GitHub"]])
    #expect(SettingsSearch.find("account", in: sections).first?.section.id == "agents")
    #expect(SettingsSearch.find("integrations", in: sections).map(\.screens) == [["Integrations"]])
    #expect(SettingsSearch.find("nothing here", in: sections).isEmpty)
}

@MainActor @Test func settingsHaveTheirShelves() {
    _ = testHome
    _ = NSApplication.shared   // the theme applies to NSApp
    let m = AppModel(builtins: Builtins.all)
    m.extensions.reload()
    let sections = m.extensions.all.settings.sorted { $0.order < $1.order }
    #expect(sections.prefix(10).map(\.id) == ["general", "appearance", "agents", "catalog", "notifications", "terminal", "editor", "git", "integrations", "keyboard"])
    let window = sections.first { $0.id == "appearance" }
    #expect(window?.specs.contains { $0.key == "workbench.inspectorIcons" } == true)   // its menu is made from it
    #expect(window?.groups.flatMap(\.1).contains { $0.key == "workbench.inspectorIcons" } == true)   // and in Settings too
    #expect(sections.first { $0.id == "git" }?.groups.map(\.0) == [nil, "CI"])
    // One row per key: the Dock icon sat in two sections with two defaults.
    let keys = sections.flatMap(\.specs).map(\.key)
    #expect(Set(keys).count == keys.count)
    // A drawn choice is an enum row somewhere: a renamed key would leave its pictures drawing nothing.
    let enums = Set(sections.flatMap(\.specs).filter { $0.type == "enum" }.map(\.key))
    #expect(SettingPictures.keys.subtracting(enums).isEmpty)
}

/// The welcome's agents: the chosen one first, the best-known after, one row at most.
@MainActor @Test func theWelcomeOffersFourAgents() {
    let installed = ["antigravity", "claude", "codex", "crush", "cursor", "pi"]
    #expect(WelcomeSetup.firstAgents(installed, current: "claude") == ["claude", "codex", "cursor", "antigravity", "crush"])
    #expect(WelcomeSetup.firstAgents(installed, current: "pi") == ["pi", "claude", "codex", "cursor", "antigravity"])
    #expect(WelcomeSetup.firstAgents(["crush"], current: "claude") == ["crush"])
}

/// A row's `requires`: on, equal, not equal, read through the defaults.
@MainActor @Test func aRowWaitsForItsParent() {
    _ = testHome
    _ = NSApplication.shared   // the theme applies to NSApp
    let m = AppModel(builtins: Builtins.all)
    m.extensions.reload()
    let s = m.settings
    #expect(s.meets(nil))
    #expect(s.meets("usage.readPlans"))                 // true by default
    #expect(!s.meets("phone.url"))                      // empty
    #expect(s.meets("agents.dockStrip"))                // "always"
    #expect(!s.meets("agents.dockStrip=needed"))
    #expect(s.meets("agents.dockStrip!=off"))
    let keys = Set(m.extensions.all.settings.flatMap(\.specs).map(\.key))
    let parents = m.extensions.all.settings.flatMap(\.specs).compactMap(\.requires).map { String($0.split(whereSeparator: { "=!".contains($0) })[0]) }
    #expect(Set(parents).subtracting(keys).isEmpty)   // each names a real setting
}

/// The Agent Catalog's ↑ ↓: the next agent as the list shows it, nothing past either end or from one filtered out.
@MainActor @Test func theCatalogsArrowsWalkItsList() {
    let shown = ["claude", "codex", "crush"]
    #expect(AgentsSettings.neighbour(of: "codex", by: 1, in: shown) == "crush")
    #expect(AgentsSettings.neighbour(of: "codex", by: -1, in: shown) == "claude")
    #expect(AgentsSettings.neighbour(of: "crush", by: 1, in: shown) == nil)
    #expect(AgentsSettings.neighbour(of: "gemini", by: 1, in: shown) == nil)
}
