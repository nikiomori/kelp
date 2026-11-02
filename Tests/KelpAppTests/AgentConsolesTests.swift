import Testing
import Foundation
import AppKit
import Core
import WorkbenchKit
@testable import KelpKit

/// A session of the workspace, known to the app.
@MainActor private func session(_ rig: AppRig, _ p: SessionCreate) async throws -> Session {
    let s = try #require(await rig.app.call(p))
    rig.app.upsert(s)
    return s
}

extension OneAtATime {
    /// What someone else starts gets a tab behind the one you're looking at: it neither covers it nor takes the pane.
    @Test func aSessionStartedElsewhereTakesNothing() async throws {
        let rig = try await AppRig(files: [:]); defer { rig.done() }
        let area = EditorArea(app: rig.app, workspaceId: rig.workspace.id)
        let mine = try await session(rig, SessionCreate(worktreeId: rig.workspace.id, command: "sleep 30"))
        area.open(TabURI.session(mine.id))
        let other = try await session(rig, SessionCreate(worktreeId: rig.workspace.id, command: "sleep 31"))
        area.reconcile()
        #expect(area.layout.tab(uri: TabURI.session(other.id)) != nil)
        #expect(area.layout.focusedGroup?.selectedTab?.uri == TabURI.session(mine.id))
    }

    /// `kelp open` beside you: the pane appears, and the one you're in stays the focused one.
    @Test func openingBesideYouLeavesYourPaneFocused() async throws {
        let rig = try await AppRig(files: [:]); defer { rig.done() }
        let area = EditorArea(app: rig.app, workspaceId: rig.workspace.id)
        area.arrangedByHand()
        let mine = try await session(rig, SessionCreate(worktreeId: rig.workspace.id, command: "sleep 30"))
        area.open(TabURI.session(mine.id))
        let other = try await session(rig, SessionCreate(worktreeId: rig.workspace.id, command: "sleep 31"))
        area.showAside(TabURI.session(other.id), split: .down)
        #expect(area.layout.root?.sessions.count == 2)
        #expect(area.layout.focusedGroup?.selectedTab?.uri == TabURI.session(mine.id))
    }
}
