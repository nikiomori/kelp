import Core
import Testing

@testable import KelpKit

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
    #expect(
        QuickOpen.headings(text) == [
            CodeSymbol(name: "Title", kind: "h1", line: 1), CodeSymbol(name: "Part two", kind: "h2", line: 3)
        ])
}

/// "#": the project's pull requests are asked once per opening, not per keystroke (each runs `gh` in the daemon, and
/// with gh missing each would say so again); what's typed after filters them.
@MainActor @Test func pullRequestsAreAskedOncePerOpening() async throws {
    let rig = try await AppRig()
    defer { rig.done() }
    let open = rig.app.quickOpen
    open.show(commandsOnly: false, text: "#1")
    let asked = try #require(open.prSearch)
    open.field.stringValue = "#12"
    open.filter()
    #expect(open.prSearch == asked, "a keystroke while they're asked asks again")
    await asked.value
    #expect(open.pullRequests?.list != nil)
    open.field.stringValue = "#123"
    open.filter()
    #expect(open.prSearch == asked, "nor once they're here")
    open.show(commandsOnly: false, text: "#1")
    #expect(open.prSearch != asked, "a new opening asks again")
    open.prSearch?.cancel()
}
