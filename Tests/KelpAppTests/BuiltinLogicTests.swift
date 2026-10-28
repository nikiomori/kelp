import AppKit
import Foundation
import JavaScriptCore
import Testing
import Core
@testable import KelpKit
@testable import BuiltinActivity
@testable import BuiltinBrowser
@testable import BuiltinFiles
@testable import BuiltinIssues

/// The built-ins' small decisions, without a window: how they word and sort what they show.

@MainActor @Test func activityShowsCPUAsItReads() {
    #expect(ActivityController.percent(3.25) == "3.2%" || ActivityController.percent(3.25) == "3.3%")
    #expect(ActivityController.percent(42.6) == "43%")
}

@MainActor @Test func anUntitledFileIsNamedAfterItsFirstLine() {
    #expect(UntitledTab.suggestedName("def main():\n    pass") == "def main()")
    #expect(UntitledTab.suggestedName("a/b:c*d?\nrest") == "abcd")
    #expect(UntitledTab.suggestedName("\n\nlater") == "later")   // the first line with text
    #expect(UntitledTab.suggestedName("  \n") == nil)
    #expect(UntitledTab.suggestedName(String(repeating: "x", count: 100))?.count == 40)
}

@MainActor @Test func theFileTreeHasFoldersFirstAndMarksWhatGitIgnores() {
    let tree = FileNode.tree(["b.txt", "src/main.swift", "a.txt"], ignored: [".build/"])
    #expect(tree.map(\.name) == [".build", "src", "a.txt", "b.txt"])
    #expect(tree.first?.ignored == true && tree.first { $0.name == "src" }?.ignored == false)
    #expect(FileNode.find("src/main.swift", in: tree)?.path == "src/main.swift")
    #expect(FileNode.find("src/nope.swift", in: tree) == nil)
}

@MainActor @Test func aPullRequestsChecksReadFailingFirst() {
    #expect(TasksViewController.checksText(.init(passed: 3, failed: 1, pending: 2)).contains("1 failing"))
    #expect(TasksViewController.checksText(.init(passed: 3, pending: 2)).contains("2 pending"))
    #expect(TasksViewController.checksText(.init(passed: 3)).contains("passed"))
    #expect(TasksViewController.checksText(.init()) == "")
}

@MainActor @Test func aMissingOrSignedOutCLISaysHowToFixIt() {
    #expect(Forge.setup(for: "gh: command not found")?.command == "brew install gh && gh auth login")
    #expect(Forge.setup(for: "You are not logged into any GitHub hosts")?.command == "gh auth login")
    #expect(Forge.setup(for: "could not resolve host github.com") == nil)
}

@MainActor @Test func aFileThatCantOpenSaysWhy() {
    #expect(FileTab.reason(.binary).contains("Binary"))
    #expect(FileTab.reason(.tooBig(60 << 20)).contains("Too big"))
    #expect(FileTab.reason(.special).contains("devices"))
}

@MainActor @Test func aCIRunReadsAsItsStatus() {
    #expect(CIRunLook.words("completed", "success") == "Succeeded")
    #expect(CIRunLook.words("completed", "failure") == "Failed")
    #expect(CIRunLook.words("in_progress", nil) == "Running")
    #expect(CIRunLook.words("queued", nil) == "Queued")
    #expect(CIRunLook.ago("not a date").isEmpty)
}

/// Design Mode's overlay is one script the page runs: a line break inside one of its strings (d4ca506 split the tag's
/// style over lines) made all of it a syntax error, and Design Mode drew nothing.
@MainActor @Test func designModesScriptParses() throws {
    let js = BrowserTab.designJS(accent: .systemBlue)
    #expect(!js.contains("ACCENT"))
    let context = try #require(JSContext())
    let literal = String(data: try JSONSerialization.data(withJSONObject: [js]), encoding: .utf8) ?? "[]"
    context.evaluateScript("new Function(\(literal)[0])")   // parses it without running it (no page here)
    #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
}
