import Foundation
import Testing

// How the app starts sessions and runs URIs: ArchitectureTests' scans, kept apart for its length.

/// A session the app starts is asked at its terminal's size (`SessionStarter`, else `workbench.sized`): the first screen
/// drawn for another width leaves zsh's stray "%" line. So is a run (a project's command, a .kelp.yaml one). It joins
/// the list through `upsert`: its event may come first.
@Test func theAppStartsSessionsSizedAndOnce() throws {
    let unsized = try matches(#"(?<!sized\(\s{0,40})\b(?:SessionCreate|ScriptsRun|RunStart)\("#, in: appDirs)
        .filter { !$0.hasPrefix("Sources/KelpKit/SessionStarter.swift:") }
    #expect(unsized == [], "a session asked without its size: \(unsized)")
    let appended = try matches(#"\bsessions\.append\("#, in: appDirs)
        .filter { !$0.hasPrefix("Sources/KelpKit/Model/AppModel.swift:") }
    #expect(appended == [], "a session added beside upsert: \(appended)")
}

/// `workbench.open` takes links from forges and trackers, so it only shows things. What runs a `terminal:` or `agent:` URI has
/// a name of its own and these callers, each with a URI Kelp made or a person asked for; data from elsewhere is never among them.
@Test func onlyKelpsOwnURIsRunAnything() throws {
    let callers = Set(try matches(#"\.runURI\("#, in: appDirs).map { String($0.split(separator: ":")[0]) })
    #expect(
        callers == [
            "Sources/KelpKit/DevAids/DevAids.swift", "Sources/KelpKit/Editor/EditorArea.swift",
            "Sources/KelpKit/Extensions/ExtActions.swift",
            "Sources/KelpKit/QuickOpen/QuickOpenTmux.swift", "Sources/KelpKit/Shell/EditorHost.swift",
            "Sources/KelpKit/Shell/KelpLinks.swift", "Sources/KelpKit/Shell/WorkbenchActions.swift"
        ])
}
