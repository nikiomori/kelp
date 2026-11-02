import Testing
@testable import KelpKit

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
