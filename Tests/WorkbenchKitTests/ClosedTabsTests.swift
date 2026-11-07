import Foundation
import Testing
import WorkbenchKit

private func tab(_ uri: String, on w: String = "w") -> ClosedTab {
    ClosedTab(uri: uri, title: uri, workspace: w, group: "g", index: 0)
}

@Test func theLatestComesFirstAndTheListStaysShort() {
    var c = ClosedTabs()
    for i in 0..<(ClosedTabs.limit + 5) { c.remember(tab("https://x/\(i)")) }
    #expect(c.all.count == ClosedTabs.limit)
    #expect(c.all.first?.uri == "https://x/\(ClosedTabs.limit + 4)")
}

@Test func aFileIsOneEntryAtWhateverLinePerScreen() {
    var c = ClosedTabs()
    c.remember(tab(TabURI.file("/a", line: 3)))
    c.remember(tab(TabURI.file("/a", line: 9)))
    c.remember(tab(TabURI.file("/a", line: 9), on: "other"))
    #expect(c.all.map(\.uri) == [TabURI.file("/a", line: 9), TabURI.file("/a", line: 9)])
    #expect(c.all.map(\.workspace) == ["other", "w"])
}

@Test func aClosedRowsTabsMoveToTheRowShownInstead() {
    var c = ClosedTabs()
    c.remember(tab("https://x/1", on: "gone"))
    c.remember(tab("https://x/2", on: "here"))
    c.move(from: "gone", to: "here")
    #expect(c.all.allSatisfy { $0.workspace == "here" })
    let first = c.all[0]
    c.forget(first)
    #expect(c.all.map(\.uri) == ["https://x/1"])
}
