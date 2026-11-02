import AppKit
import Core
import Foundation
import Testing
import WorkbenchKit
@testable import KelpKit
@testable import BuiltinFiles

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
        let rig = try await AppRig(files: [:]); defer { rig.done() }
        let (tab, path) = try await opened(rig, text: "draft")
        for _ in 0..<200 where tab.typed == nil { try await Task.sleep(for: .milliseconds(10)) }
        tab.type("long prompt\n")
        #expect(await tab.close())
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "long prompt\n")
        #expect(FileManager.default.fileExists(atPath: path + TabURI.promptDone))
    }
}

extension AppOfItsOwn {
    @Test func theFirstTaskFieldGrowsToSixLinesAndKeepsWhatsTyped() {
        let field = StartPrompt(placeholder: "", accessibilityLabel: "")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = field
        var kept = ""
        field.onChange = { kept = $0 }
        field.value = "one"
        window.layoutIfNeeded()
        let one = field.fittingSize.height
        field.value = "1\n2\n3"
        window.layoutIfNeeded()
        #expect(abs(field.fittingSize.height - one * 3) <= 3)
        field.value = String(repeating: "x\n", count: 30)
        window.layoutIfNeeded()
        #expect(abs(field.fittingSize.height - one * 6) <= 6)
        #expect(kept.count == 60)
    }
}
