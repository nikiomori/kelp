import AppKit
import Core
import Foundation
import Testing

@testable import BuiltinAgents
@testable import KelpApp
@testable import KelpKit

/// A terminal out of sight lets go of its surface after a while, Pause idle agents off or not (only sooner when it's
/// on); it isn't "Session ended" meanwhile, and shown again it attaches anew. All in one main-actor turn: the attach's
/// own exit (no `kelp` beside the test runner) can't come in between.
@MainActor @Test func aHiddenTerminalLetsGoOfItsSurfaceWithoutLookingStopped() throws {
    _ = testHome
    #expect(PaneView.offScreenWait(hibernateMinutes: 0) == PaneView.releaseAfter)
    #expect(PaneView.offScreenWait(hibernateMinutes: 1) == min(60, PaneView.releaseAfter))
    let app = AppModel(builtins: Builtins.all)
    let s = Session(id: "s1", cwd: "/", command: "claude", agent: "claude", status: .idle)
    app.upsert(s)
    app.connected = true
    let pane = PaneView(session: s, app: app)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    window.contentView?.addSubview(pane)
    pane.removeFromSuperview()
    #expect(pane.offScreen != nil)   // timed with the setting at its default (0, off)
    pane.offScreen?.cancel()
    pane.letGo()
    #expect(pane.ghostty == nil && pane.released)
    pane.update(s)   // a status change while it's hidden
    #expect(pane.endedHeight.constant == 0)
    window.contentView?.addSubview(pane)
    #expect(pane.ghostty != nil && !pane.released && pane.offScreen == nil)
    #expect(pane.endedHeight.constant == 0)
}
