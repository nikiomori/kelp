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
}
