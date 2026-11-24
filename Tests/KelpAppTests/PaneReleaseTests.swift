import AppKit
import Core
import Foundation
import TestSupport
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

/// A file dragged over an agent's pane shows where it will land, as over an editor pane: the drop hint across the pane,
/// made only once something is dragged there. It goes when the drag leaves.
@MainActor @Test func aDragOverAnAgentsPaneShowsWhereItLands() async throws {
    _ = testHome
    let app = AppModel(builtins: Builtins.all)
    let s = Session(id: "s2", cwd: "/", command: "claude", agent: "claude", status: .idle)
    app.upsert(s)
    let pane = PaneView(session: s, app: app)
    pane.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    #expect(!pane.subviews.contains { $0 is DropHint })
    let drag = Drag()
    #expect(pane.draggingEntered(drag) == .copy)
    let hint = try #require(pane.subviews.last as? DropHint)
    #expect(!hint.isHidden && hint.frame == DropHint.across(pane.bounds))
    pane.draggingExited(drag)
    try await waitFor { hint.isHidden }
}

/// A drag in progress, as AppKit hands one to a view it is over.
private final class Drag: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}
