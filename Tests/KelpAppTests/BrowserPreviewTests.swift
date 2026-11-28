import AppKit
import Foundation
import TestSupport
import Testing

@testable import BuiltinBrowser
@testable import KelpKit

/// WebKit pages load slowly under a parallel run's load, so this one runs alone, as the other pages' tests do.
extension OneAtATime {
    /// A local page loads again when a file in its folder changes, but not for git's own files, and a tab off screen
    /// loads once when it shows instead of on every change.
    @Test func aPreviewLoadsAgainForItsFilesOnceShownButNotForGit() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let page = dir + "/index.html"
        try "<p>hi</p>".write(toFile: page, atomically: true, encoding: .utf8)
        let tab = BrowserTab(uri: "preview:" + page, app: AppModel())
        #expect(try await waitFor(30) { tab.web.url != nil && !tab.web.isLoading })

        tab.previewChanged([dir + "/.git/FETCH_HEAD", dir + "/.git"])
        tab.previewChanged([page])
        #expect(!tab.web.isLoading)   // off screen: it waits
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.contentView = tab.view
        #expect(tab.web.isLoading)   // shown: once
        #expect(try await waitFor(30) { !tab.web.isLoading })

        tab.previewChanged([dir + "/.git/index"])
        #expect(!tab.web.isLoading)
        tab.previewChanged([dir + "/css/site.css"])
        #expect(tab.web.isLoading)
    }
}

@Test(arguments: [
    ("/r/.git", true), ("/r/.git/index", true), ("/r/.git/refs/heads/main", true), ("/r/index.html", false),
    ("/r/.github/x.yml", false), ("/r/a.gitignore", false)
])
func gitsOwnFiles(path: String, inGit: Bool) {
    #expect(BrowserTab.inGit(path) == inGit)
}
