import AppKit
import Core
import Foundation
import TestSupport
import Testing
import WorkbenchKit

@testable import BuiltinFiles
@testable import KelpKit

/// A prompt handed over by an agent: closing puts the text back and says so beside the file; Cancel only says so.
extension AppOfItsOwn {
    private func opened(_ rig: AppRig, text: String) async throws -> (PromptTab, String) {
        let path = rig.root.path + "/prompt with space.md"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        let tab = PromptTab(uri: TabURI.prompt(path), app: rig.app)
        return (tab, path)
    }

    @Test func aPromptsURIKeepsItsPath() {
        #expect(TabURI.promptPath(TabURI.prompt("/tmp/a b/c.md")) == "/tmp/a b/c.md")
        #expect(TabURI.scheme(TabURI.prompt("/x")) == "prompt")
    }

    @Test func closingAPromptWritesItsTextAndSaysItsDone() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let (tab, path) = try await opened(rig, text: "draft")
        #expect(try await waitFor(5) { !(tab.typed == nil) })
        tab.type("long prompt\n")
        #expect(await tab.close())
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "long prompt\n")
        #expect(FileManager.default.fileExists(atPath: path + TabURI.promptDone))
    }
}

extension AppOfItsOwn {
    @Test func theFirstTaskFieldGrowsToSixLinesAndKeepsWhatsTyped() {
        UserDefaults.standard.set("Always", forKey: "AppleShowScrollBars")   // with a mouse: the scroller takes its width
        defer { UserDefaults.standard.removeObject(forKey: "AppleShowScrollBars") }
        let field = StartPrompt(placeholder: "", accessibilityLabel: "")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.contentView = field
        var kept = ""
        field.onChange = { kept = $0 }
        field.layoutSubtreeIfNeeded()
        field.value = "x"
        let one = field.fittingSize.height
        field.value = "1\n2\n3"
        #expect(abs(field.fittingSize.height - one * 3) <= 3)
        field.value = String(repeating: "word ", count: 150)   // no line ends: the rows are the ones it wraps into
        #expect(field.fittingSize.height >= one * 2)
        field.value = String(repeating: "x\n", count: 30)
        #expect(abs(field.fittingSize.height - one * 6) <= 6)
        #expect(kept.count == 60)
    }
}

extension AppOfItsOwn {
    /// A server's change: the tab's own file in its buffer, for its undo; another file written; one with unsaved edits holds it all.
    @Test func aServersChangeReachesTheBufferAndOtherFiles() async throws {
        let rig = try await AppRig(files: ["a.txt": "old\n", "b.txt": "old\n"])
        defer { rig.done() }
        rig.app.worktrees = [rig.workspace]
        let a = rig.workspace.path + "/a.txt", b = rig.workspace.path + "/b.txt"
        let tab = FileTab(uri: TabURI.file(a), app: rig.app)
        await tab.loading?.value
        let edit = [CodeEdit(line: 0, column: 0, endLine: 0, endColumn: 3, text: "new")]
        await tab.server.apply([CodeFileEdit(path: a, edits: edit), CodeFileEdit(path: b, edits: edit)])
        #expect(tab.editor?.text == "new\n")
        #expect(try String(contentsOfFile: b, encoding: .utf8) == "new\n")
        #expect(try String(contentsOfFile: a, encoding: .utf8) == "old\n")   // unsaved, as a typed change is
    }
}
