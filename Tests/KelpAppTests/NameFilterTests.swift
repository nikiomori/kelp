import AppKit
import Foundation
import TestSupport
import Testing

@testable import BuiltinFiles
@testable import KelpKit

@Test func aNameSearchIsWordsAPathMustHold() {
    let f = NameFilter("swift daemon !test")
    #expect(f.matches("Sources/Daemon/LSPHost.swift", changed: false))
    #expect(!f.matches("Tests/DaemonTests/x.swift", changed: false))   // left out
    #expect(!f.matches("Sources/Daemon/README.md", changed: false))   // not every word
    #expect(NameFilter("Sources/Daemon/").matches("sources/daemon/a", changed: false))
    // A name on disk with й decomposed (и + combining breve) is found by the й typed, upper case too.
    #expect(NameFilter("Й").matches("docs/\u{0438}\u{0306}ога.md", changed: false))
    #expect(NameFilter("\u{0438}\u{0306}").matches("docs/йога.md", changed: false))
}

@Test func changedKeepsWhatGitTouched() {
    let f = NameFilter(":changed swift")
    #expect(f.matches("a.swift", changed: true))
    #expect(!f.matches("a.swift", changed: false))
    #expect(NameFilter(" ").isEmpty)
    #expect(!NameFilter("!").isEmpty)   // a lone ! is a word like any other
}

extension AppOfItsOwn {
    /// The tree narrows in place, folders keeping their shape and open; emptying the field brings it all back.
    @Test func aNameSearchNarrowsTheTreeInPlace() async throws {
        _ = NSApplication.shared
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        try FileManager.default.createDirectory(atPath: rig.repo + "/src/deep", withIntermediateDirectories: true)
        for f in ["src/deep/server.swift", "src/other.txt", "readme.md"] { try rig.write(f, "x") }
        let panel = FilesPanel(app: rig.app)
        rig.show(panel, 300, 500)
        panel.viewWillAppear()
        #expect(try await waitFor(5) { !(panel.outline.numberOfRows == 0) })
        #expect(panel.outline.numberOfRows == 2)   // readme and src, shut

        panel.searchBy(name: true)
        panel.search.stringValue = "server !zz"
        panel.narrowTree()
        let shown = (0..<panel.outline.numberOfRows).compactMap { (panel.outline.item(atRow: $0) as? FileNode)?.name }
        #expect(shown == ["src", "deep", "server.swift"])
        #expect(panel.isNarrowed)

        panel.search.stringValue = ""
        panel.narrowTree()
        #expect(panel.outline.numberOfRows == 2)
        #expect(!panel.isNarrowed)
        UserDefaults.standard.removeObject(forKey: "files.searchByName")
    }
}
