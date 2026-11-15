import AppKit
import Core
import Foundation
import TestSupport
import Testing
import WorkbenchKit

@testable import BuiltinActivity
@testable import BuiltinAgents
@testable import BuiltinBrowser
@testable import BuiltinFiles
@testable import BuiltinGit
@testable import BuiltinIssues
@testable import EditorKit
@testable import KelpApp
@testable import KelpKit

/// What typing, saving and the language server's copy of the text cost the main thread in a file near the editable
/// limit. Opt-in, it takes seconds: KELP_BENCH=1 swift test --filter editorBench
extension OneAtATime {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KELP_BENCH"] != nil)) func editorBench() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let line = "    let value = compute(index: 42, label: \"größe\") // a line of code\n"
        try rig.write("big.swift", String(repeating: line, count: 4_700_000 / line.utf8.count))
        let p = rig.repo + "/big.swift"
        let tab = FileTab(uri: TabURI.file(p), app: rig.app)
        #expect(try await waitFor(60) { tab.editor != nil })   // read by the daemon first
        let e = try #require(tab.editor), tv = e.textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.contentView = tab.view
        window.contentView?.layoutSubtreeIfNeeded()
        func time(_ n: Int, _ body: () -> Void) -> Double {
            let t0 = Date()
            for _ in 0..<n { body() }
            return Date().timeIntervalSince(t0) * 1000 / Double(n)
        }
        let end = tv.length - 100   // at the end: a compare with the saved text runs through all of it
        let onChange = e.onChange
        e.onChange = nil
        let bare = time(30) { tv.replace([NSRange(location: end, length: 0)], with: ["x"]) }
        e.onChange = onChange
        let typed = time(30) { tv.replace([NSRange(location: end, length: 0)], with: ["x"]) }
        #expect(tab.isEdited)
        let t0 = Date()
        #expect(await tab.save())
        let save = Date().timeIntervalSince(t0) * 1000
        #expect(!tab.isEdited)
        let overtype = time(10) { tv.replace([NSRange(location: end, length: 1)], with: ["y"]) }   // the saved length
        let text = e.text
        let lsp = time(1) { LSPManager.of(rig.app).change(root: rig.repo, path: p, text: text) }
        print(
            String(
                format:
                    "BENCH editor %.1f MB on the main thread: keystroke %.2f ms (the editor alone %.2f), same-length edit %.2f ms, lsp.change %.2f ms; save took %.0f ms",
                Double(text.utf8.count) / 1e6, typed, bare, overtype, lsp, save))
    }

    /// What a key typed costs the main thread in a file tab on screen, all of it: the keystroke, the coloring pass after it
    /// and the background parse's coloring when it comes in. A 5 MB Swift file, a 2 MB Markdown one under a top heading
    /// (sticky scroll, its section to the end). Opt-in: KELP_BENCH=1 swift test --filter editorTypingBench
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KELP_BENCH"] != nil)) func editorTypingBench() async throws
    {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        rig.app.settings.set(SettingKeys.markdownMode, "edit")
        let code = "    let value = compute(index: 42, label: \"größe\") // a line of code\n"
        let prose = "Some words of a paragraph, as a spec has them, and a few more of them.\n"
        try rig.write(
            "big.swift", "func top() {\n" + String(repeating: code, count: 5_000_000 / code.utf8.count) + "}\n")
        try rig.write("big.md", "# Plan\n\n## Part\n\n" + String(repeating: prose, count: 2_000_000 / prose.utf8.count))
        for name in ["big.swift", "big.md"] {
            let t0 = Date()
            let tab = FileTab(uri: TabURI.file(rig.repo + "/" + name), app: rig.app)
            await tab.loading?.value
            let e = try #require(tab.editor), tv = e.textView
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered,
                defer: true)
            window.contentView = tab.view
            window.contentView?.layoutSubtreeIfNeeded()
            let open = Date().timeIntervalSince(t0) * 1000
            func drained() async { await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } } }
            e.goTo(line: 400)
            e.scroll(toLine: 380)
            await drained()
            try await Task.sleep(for: .seconds(2))   // the first parse
            var parsing = 0.0, parsed = false
            let colored = e.highlighter?.parsed
            e.highlighter?.parsed = {
                let p0 = Date()
                colored?()
                parsing += Date().timeIntervalSince(p0) * 1000
                parsed = true
            }
            var typing = 0.0
            let keys = 40
            for _ in 0..<keys {
                parsed = false
                let k0 = Date()
                tv.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
                await drained()   // the coloring pass the edit asked for
                typing += Date().timeIntervalSince(k0) * 1000
                for _ in 0..<400 where !parsed { try await Task.sleep(for: .milliseconds(5)) }
                await drained()
            }
            print(
                String(
                    format:
                        "BENCH typing %@: %.2f ms a key on the main thread (keystroke and its pass %.2f, parse's coloring %.2f); opened in %.0f ms",
                    name, (typing + parsing) / Double(keys), typing / Double(keys), parsing / Double(keys), open))
        }
    }

    /// How long a file takes to open (until its text is in the editor) and to save, through whatever reads and writes it.
    /// Opt-in: KELP_BENCH=1 swift test --filter fileOpenSaveBench
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KELP_BENCH"] != nil)) func fileOpenSaveBench() async throws
    {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let line = "    let value = compute(index: 42, label: \"größe\") // a line of code\n"
        for (name, size) in [("small.swift", 200_000), ("big.swift", 5_000_000)] {
            try rig.write(name, String(repeating: line, count: size / line.utf8.count))
            var opens: [Double] = [], saves: [Double] = []
            for i in 0..<5 {
                let t0 = Date()
                let tab = FileTab(uri: TabURI.file(rig.repo + "/" + name), app: rig.app)
                while tab.editor == nil { try await Task.sleep(for: .milliseconds(1)) }   // timed, to the ms
                opens.append(Date().timeIntervalSince(t0) * 1000)
                let e = try #require(tab.editor)
                e.setText(e.text + "// \(i)\n")
                e.onChange?(e.text)
                let t1 = Date()
                #expect(await tab.save())
                saves.append(Date().timeIntervalSince(t1) * 1000)
            }
            print(
                String(
                    format: "BENCH file %@ %.1f MB: open %.1f ms, save %.1f ms (medians of 5)", name,
                    Double(size) / 1e6,
                    opens.sorted()[2], saves.sorted()[2]))
        }
    }
}
