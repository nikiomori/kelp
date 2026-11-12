import AppKit
import Core
import Testing

@testable import BuiltinAgents
@testable import KelpApp
@testable import KelpKit

@MainActor @Test func aPickerListsAValueFromOutsideItsChoices() {
    #expect(SettingRow.shown(["block", "bar"], "bar") == ["block", "bar"])
    #expect(SettingRow.shown(["block", "bar"], "beam") == ["block", "bar", "beam"])
    #expect(SettingRow.shown(["block", "bar"], "") == ["block", "bar"])
}

@Test func aNumberWithARangeStaysInIt() {
    let size = SettingSpec(key: "k", title: "T", type: .number, range: [8, 40])
    #expect(size.clamped(-3) == 8 && size.clamped(13) == 13 && size.clamped(200) == 40)
    #expect(SettingSpec(key: "k", title: "T", type: .number).clamped(-3) == -3)
    #expect(SettingSpec(key: "k", title: "T", type: .number, range: [8]).bounds == nil)   // from an extension.json: ignored
}

@MainActor @Test func searchFindsGroupsSectionsAndWhatAPageDeclares() {
    func row(_ key: String, _ title: String, group: String? = nil) -> SettingSpec {
        SettingSpec(key: key, title: title, type: .boolean, group: group)
    }
    let sections = [
        SettingsSection(
            id: "agents", title: "Agents", icon: "",
            specs: [
                row("a.one", "Keep Mac awake"), row("a.two", "When it fails", group: "Notifications"),
                row("a.three", "When it waits", group: "Notifications")
            ], keywords: ["Accounts"]),
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
    #expect(
        sections.prefix(12).map(\.id) == [
            "general", "appearance", "agents", "catalog", "notifications", "terminal", "editor", "languages",
            "databases", "git", "integrations", "keyboard"
        ])
    let window = sections.first { $0.id == "appearance" }
    #expect(window?.specs.contains { $0.key == "workbench.inspectorIcons" } == true)   // its menu is made from it
    #expect(window?.groups.flatMap(\.1).contains { $0.key == "workbench.inspectorIcons" } == true)   // and in Settings too
    #expect(sections.first { $0.id == "git" }?.groups.map(\.0) == [nil, "CI"])
    // One row per key: the Dock icon sat in two sections with two defaults.
    let keys = sections.flatMap(\.specs).map(\.key)
    #expect(Set(keys).count == keys.count)
    // A drawn choice is an enum row, and every one has its drawings, the shell's or its own (`choices`): a renamed key
    // would leave the shell's drawing nothing.
    let pictured = sections.flatMap(\.specs).filter { $0.look == .pictures }
    #expect(pictured.allSatisfy { $0.type == .enum })
    #expect(Set(pictured.filter { $0.choices?.picture == nil }.map(\.key)) == SettingPictures.keys)
    // What an option is called comes from where its setting is declared, the window naming no built-in's key.
    #expect(SettingRow.label(SettingKeys.dockStrip.key, "needed", m) == "When Needed")
    #expect(SettingRow.label(SettingKeys.ciBranchChip.key, "icon", m) == "In Place of the Branch Icon")
    #expect(SettingRow.label(SettingKeys.serverLook.key, "fade", m) == "Stripes by the Icon")
    #expect(SettingRow.label(SettingKeys.alertAt.key, "80", m) == "80%")
    #expect(SettingRow.label(SettingKeys.hibernateMinutes.key, "240", m) == "After 4 Hours")
    #expect(SettingRow.label(SettingKeys.usageLimits.key, "all", m) == "All Agents")
    #expect(SettingRow.label(SettingKeys.textSize.key, "large", m) == "Large")   // not named: its value, capitalized
}

/// The welcome's agents: the chosen one first, the best-known after, one row at most.
@MainActor @Test func theWelcomeOffersFourAgents() {
    let installed = ["antigravity", "claude", "codex", "crush", "cursor", "pi"]
    #expect(
        WelcomeSetup.firstAgents(installed, current: "claude") == ["claude", "codex", "cursor", "antigravity", "crush"])
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
    #expect(s.meets("usage.readPlans"))   // true by default
    #expect(!s.meets("phone.url"))   // empty
    #expect(s.meets("agents.dockStrip"))   // "always"
    #expect(!s.meets("agents.dockStrip=needed"))
    #expect(s.meets("agents.dockStrip!=off"))
    let keys = Set(m.extensions.all.settings.flatMap(\.specs).map(\.key))
    let parents = m.extensions.all.settings.flatMap(\.specs).compactMap(\.requires).map {
        String($0.split(whereSeparator: { "=!".contains($0) })[0])
    }
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

/// Every setting declared in code (`SettingKeys`, in Core or the module that reads it) is a row in Settings, which is how
/// search, Quick Open and the agents' settings guide know it, or it's on this list with why. A key left without a row
/// used to go unnoticed: only the people who read the code knew it was there.
@MainActor @Test func everyDeclaredSettingHasARow() throws {
    let noRow = [
        "accounts.profiles": "the accounts are a list of their own, under Settings › Agents",
        "extensions.disabled": "Settings › Extensions' switches",
        "editor.languageServers": "a language server's own options and settings, by its command: settings.json only",
        "keys": "the shortcuts set by hand: Settings › Keyboard is a page of its own",
        "extensions.library": "where the library's index is: settings.json only, for someone running their own",
        "usage.readClaudePlan": "Show plan limits' old name, read while the new one isn't set",
        "workbench.inspector.panelOrder": "the inspector's icons as they were dragged"
    ]
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let declaration = /static let \w+ = Setting(?:<[^\n]*?>)?\(\s*"([^"]+)"/
    var declared: Set<String> = []
    let sources = root.appendingPathComponent("Sources")
    for case let file as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
        .allObjects ?? [] where file.pathExtension == "swift"
    {
        let text = try String(contentsOf: file, encoding: .utf8)
        for match in text.matches(of: declaration) { declared.insert(String(match.1)) }
    }
    #expect(declared.count > 80, "\(declared.count): the declarations weren't found")
    let app = AppModel(builtins: Builtins.all)
    let rows = Set(Builtins.all.flatMap { $0.contribute(app).settings.flatMap(\.specs).map(\.key) })
    #expect(declared.subtracting(rows).subtracting(noRow.keys).sorted() == [], "a setting with no row")
    #expect(Set(noRow.keys).intersection(rows).sorted() == [], "a row now: take it off the list")
}
