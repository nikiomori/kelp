import AppKit
import Core
import Foundation
import Testing

@testable import KelpKit

/// What the shell keeps and asks while its calls to the daemon are under way, or failed.
@MainActor @Suite(.serialized) struct ShellStateTests {
    init() { _ = NSApplication.shared }   // a failed call's banner needs an app

    /// A key being saved reads as saved at once: a second change made from what it reads meanwhile (a trusted
    /// extension's list, the pages seen) keeps the first.
    @Test func aKeyBeingSavedReadsAsSaved() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let state = rig.app.uiState
        let first = Task { await state.save("seen", .array(["a"])) }
        await Task.yield()
        let second = await state.save("seen", .array(state.strings("seen").map(JSONValue.string) + ["b"]))
        #expect(await first.value && second)
        #expect(state.strings("seen") == ["a", "b"])
    }

    /// Deleting a workspace whose uncommitted work can't be read asks nothing: a question would read as if nothing
    /// would be lost. The failed call's banner says why.
    @Test func aWorkspaceThatCantBeCheckedIsntOfferedForDeletion() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let gone = Worktree(id: "gone", repoId: rig.project.id, branch: "x", path: "/nonexistent/x")
        #expect(await WorkspaceActions(rig.app).deleteQuestion(gone) == nil)
        #expect(await WorkspaceActions(rig.app).deleteQuestion(rig.workspace) != nil)
    }

    /// The pages agents made in a workspace are found before its folder goes, so the question can offer to keep them.
    @Test func aWorkspacesPagesAreFoundBeforeItsFolderGoes() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        for page in ["plan", "deck"] {
            let folder = rig.workspace.path + "/.kelp/artifacts/" + page
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try "{}".write(toFile: folder + "/artifact.json", atomically: true, encoding: .utf8)
        }
        try "/.kelp/artifacts/\n".write(
            toFile: rig.workspace.path + "/.git/info/exclude", atomically: true, encoding: .utf8)
        let pages = await WorkspaceActions(rig.app).pages(in: rig.workspace)
        #expect(pages.sorted() == [".kelp/artifacts/deck/", ".kelp/artifacts/plan/"])
        let alert = NSAlert()
        WorkspaceActions(rig.app).offerKeeping(pages, in: alert)
        #expect(alert.showsSuppressionButton && alert.suppressionButton?.state == .on)
    }
}

/// A key the daemon refuses (trust, written by anyone but Kelp's window) isn't kept: the save says so, and the value
/// that was there reads back.
extension OneAtATime {
    @Test func aKeyTheDaemonRefusesReadsAsBefore() async throws {
        _ = NSApplication.shared   // the refusal's banner needs an app
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let state = rig.app.uiState, key = ExtensionFiles.extensionTrustKey
        #expect(await state.save(key, .object(["a": true])))
        let me = ProcessInfo.processInfo.environment["KELP_APP_EXECUTABLE"]   // this test runner stands in for the app…
        setenv("KELP_APP_EXECUTABLE", "/nowhere/KelpApp", 1)   // …not now: another copy of Kelp is asking
        defer { if let me { setenv("KELP_APP_EXECUTABLE", me, 1) } }
        #expect(await !state.save(key, .object(["b": true])))
        #expect(state[key] == .object(["a": true]))
    }
}
