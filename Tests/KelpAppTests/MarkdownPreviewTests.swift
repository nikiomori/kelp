import AppKit
import Foundation
import TestSupport
import Testing
import WebKit

@testable import BuiltinFiles
@testable import EditorKit
@testable import KelpKit

/// A window the preview sits in: kept, as a view only holds its window weakly.
@MainActor private enum PreviewWindow { static var kept: [NSWindow] = [] }

extension OneAtATime {
    /// A pause in the typing gives the page shown its new body in place: it used to load a new page each time, mermaid's
    /// and KaTeX's scripts read again and the reader's place put back.
    @Test func aPreviewTakesTheNewBodyInPlace() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/swap.md")
        let editor = CodeEditor(text: "# One\n", url: url)
        let tab = MarkdownTab(editor: editor, url: url, app: AppModel())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.contentView = tab.view
        PreviewWindow.kept.append(window)
        tab.modeSegment = 2
        func page(_ js: String) async -> Any? {
            try? await tab.web.evaluateJavaScript(js, contentWorld: MarkdownTab.world)
        }
        let heading = "document.querySelector('h1')?.textContent ?? ''"
        #expect(try await waitFor(10) { await page(heading) as? String == "One" && !tab.web.isLoading })
        _ = await page("window.kept = 1; true")
        editor.setText("# Two\n")
        tab.rerender()
        #expect(try await waitFor(10) { await page(heading) as? String == "Two" })
        #expect(await page("window.kept ?? 0") as? Int == 1)   // the same page
    }

    /// A page opened in Source mode in a wide pane gives the source the whole pane. The divider used to go to the middle
    /// with the page hidden, and the source came out as wide as its gutter, so each parse colored an empty screen, which
    /// tree-sitter took as the whole file (220 ms a key in a 2 MB page).
    @Test func aPageOpenedInSourceModeFillsThePane() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/wide.md")
        let editor = CodeEditor(text: "# One\n", url: url)
        let tab = MarkdownTab(editor: editor, url: url, app: AppModel())
        _ = tab.view   // loading it sets the mode from the settings
        tab.modeSegment = 0   // before the tab has a size, as when it opens
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.contentView = tab.view
        PreviewWindow.kept.append(window)
        let fits = try await waitFor(3) {
            tab.split.bounds.width > 700 && editor.view.frame.width > tab.split.bounds.width - 10
        }
        #expect(fits, "\(editor.view.frame.width) of \(tab.split.bounds.width)")
    }
}
