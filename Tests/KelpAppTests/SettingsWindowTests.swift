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
