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
}
