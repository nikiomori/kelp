import Core
import TestSupport
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

/// "#": the project's open pull requests are Issues', as its watch read them last (no `gh` run for a keystroke); what's
/// typed after filters them.
@MainActor @Test func pullRequestsComeFromTheirWatch() async throws {
    let rig = try await AppRig()
    defer { rig.done() }
    rig.app.extensions.reload()   // "#" is the Issues built-in's
    rig.app.workbench.workspaceId = rig.workspace.id
    let fix = GitHub.PullRequest(
        number: 7, title: "Fix login", url: "", author: "amy", headRefName: "fix", isDraft: false, state: "OPEN", checks: .init())
    // The watch's own first reading (this folder has no GitHub remote) lands before the one the test stands in for.
    #expect(try await waitFor(10) { rig.app.latest(PRsEvent.self, rig.workspace.repoId) != nil })
    rig.app.land(PRsEvent(repo: rig.workspace.repoId, prs: [fix]))
    let open = rig.app.quickOpen
    func shown(_ typed: String) async -> [String] {
        open.show(commandsOnly: false, text: typed)
        await open.prefixedLoad?.value
        return open.rows.compactMap { if case .item(let it) = $0 { it.title } else { nil } }
    }
    #expect(await shown("#7") == ["#7 Fix login"])
    #expect(await shown("#login") == ["#7 Fix login"])
    #expect(await shown("#9").isEmpty)
    rig.app.land(PRsEvent(repo: rig.workspace.repoId, error: "GitHub CLI isn't signed in — run gh auth login."))
    #expect(await shown("#") == ["GitHub CLI isn't signed in — run gh auth login."])
}
