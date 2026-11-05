import Foundation
import Testing
import Core
import GitKit
@testable import Daemon

/// A running agent changes screens within its folder and goes on as it was; a checkout elsewhere is other files.
@Test func anAgentMovesBetweenScreensOfItsFolder() async throws {
    let (d, c, _, repo) = try await world(); defer { d.stop() }
    let workspace: Worktree = try await c.call("workspace.create", .obj(["repoId": .string(repo.id)]), as: Worktree.self)
    let first = try #require(try await c.call("worktree.list", .obj(["repoId": .string(repo.id)]), as: [Worktree].self).first { $0.id != workspace.id })
    let s: Session = try await c.call("session.create", .obj(["worktreeId": .string(first.id), "command": "sleep 60"]), as: Session.self)
    func now() async throws -> Session? { try await c.call("session.list", as: [Session].self).first { $0.id == s.id } }
    _ = try await c.call("session.move", .obj(["id": .string(s.id), "worktreeId": .string(workspace.id)]))
    #expect(try await waitFor(5) { try await now()?.worktreeId == workspace.id })
    let moved = try await now()
    #expect(moved?.status != .exited && moved?.pid == s.pid)   // the same process
    let branch: Worktree = try await c.call("worktree.create", .obj(["repoId": .string(repo.id), "branch": "elsewhere"]), as: Worktree.self)
    await #expect(throws: RPCError.self) {
        try await c.call("session.move", .obj(["id": .string(s.id), "worktreeId": .string(branch.id)]))
    }
    #expect(try await now()?.worktreeId == workspace.id)
}

/// New Chat on Branch asks for no name: the first prompt gives one to the group and the branch, in any language.
@Test func theFirstPromptNamesAChatsGroupAndBranch() async throws {
    let (d, c, _, repo) = try await world(); defer { d.stop() }
    let w: Worktree = try await c.call("worktree.create", .obj(["repoId": .string(repo.id), "setup": false]), as: Worktree.self)
    #expect(w.isUnnamed && w.branch == "ws-2")
    _ = try await c.call("session.create", .obj(["worktreeId": .string(w.id), "command": "sleep 60", "prompt": "почини вход"]), as: Session.self)
    func now() async throws -> Worktree? {
        try await c.call("worktree.list", .obj(["repoId": .string(repo.id)]), as: [Worktree].self).first { $0.id == w.id }
    }
    #expect(try await waitFor { try await now()?.branch == "pocini-vhod" })
    let named = try await now()
    #expect(named?.note == "Почини вход" && named?.path == w.path)
    #expect(Git.branchExists(repo.path, "pocini-vhod") && !Git.branchExists(repo.path, "ws-2"))
}

@Test func branchesKelpNamesTakeTheSettingsPrefix() async throws {
    let (d, c, _, repo) = try await world(); defer { d.stop() }
    _ = try await c.call("settings.set", .obj(["key": "git.branchPrefix", "value": "me/"]))
    let w: Worktree = try await c.call("worktree.create", .obj(["repoId": .string(repo.id), "setup": false]), as: Worktree.self)
    _ = try await c.call("session.create", .obj(["worktreeId": .string(w.id), "command": "sleep 60", "prompt": "fix login"]))
    func now() async throws -> Worktree? {
        try await c.call("worktree.list", .obj(["repoId": .string(repo.id)]), as: [Worktree].self).first { $0.id == w.id }
    }
    #expect(try await waitFor { try await now()?.branch == "me/fix-login" })
}

@Test func aBranchNameComesOutInLatinLetters() {
    #expect(Naming.slug("Add a dark-mode toggle to Settings!") == "add-dark-mode-toggle-settings")
    #expect(Naming.slug("исправь объект в логине") == "isprav-obekt-v-logine")
    #expect(Naming.slug("修复登录") == "xiu-fu-deng-lu")
    #expect(Naming.slug("🎉🎉") == "")
}
