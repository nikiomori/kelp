import Testing
@testable import KelpKit
import Core

@MainActor @Test func theFirstCharacterSaysWhatQuickOpenLists() {
    #expect(QuickOpen.Prefix(":120") == .line(120))
    #expect(QuickOpen.Prefix(":120:8") == .line(120, column: 8))
    #expect(QuickOpen.Prefix(":") == .line(nil))
    #expect(QuickOpen.Prefix("/Sources/Daemon") == .files("Sources/Daemon"))
    #expect(QuickOpen.Prefix("file:notes") == .files("notes"))
    #expect(QuickOpen.Prefix("@init") == .symbols("init"))
    #expect(QuickOpen.Prefix("@@Basket") == .everywhere("Basket"))
    #expect(QuickOpen.Prefix("plain") == nil)
    #expect(QuickOpen.Prefix("#12") == nil)
}

@Test func headingsAreMarkdownsSymbols() {
    let text = "# Title\ntext\n## Part two\n```\n# not one\n```\n#tag\n"
    #expect(QuickOpen.headings(text) == [CodeSymbol(name: "Title", kind: "h1", line: 1), CodeSymbol(name: "Part two", kind: "h2", line: 3)])
}
