import AppKit
import Testing

@testable import DesignKit

/// A press takes 4 pt off a long control and at most a tenth off a small one, or a bar under a terminal shrinks by 90 pt.
@MainActor @Test func aPressDipsByPointsNotByShare() {
    func taken(_ w: CGFloat, _ h: CGFloat = 24) -> CGFloat {
        (1 - Motion.pressDip(CGSize(width: w, height: h))) * max(w, h)
    }
    #expect(abs(taken(22, 22) - 2.2) < 0.01)
    #expect(abs(taken(180) - 4) < 0.01)
    #expect(abs(taken(900) - 4) < 0.01)
}

/// Rings and glows started at different moments still keep step: each starts on the clock's beat, already past.
@MainActor @Test func endlessMotionStartsOnTheBeat() {
    let start = Motion.beat(2.4)
    #expect(start <= CACurrentMediaTime())
    #expect(abs(remainder(start, 2.4)) < 0.001)   // rounding can leave it just under a multiple
}

/// A tree of one long row under another, for `anOutlinesColumnStaysThePanelsWidth`.
@MainActor
private final class LongRows: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { item == nil ? 1 : 1 }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        item == nil ? "run" as NSString : "job" as NSString
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item as? NSString == "run" }
    func outlineView(_ outlineView: NSOutlineView, viewFor column: NSTableColumn?, item: Any) -> NSView? {
        let cell = NSTableCellView()
        cell.pin(NSTextField(labelWithString: String(repeating: "a long title of a run ", count: 8)))
        return cell
    }
}

/// Opening a row doesn't widen the column to the row's words: its right-hand end went past the panel's edge.
@MainActor @Test func anOutlinesColumnStaysThePanelsWidth() {
    let outline = NSOutlineView(), rows = LongRows()
    let scroll = outline.plainList("rows")
    scroll.frame = NSRect(x: 0, y: 0, width: 240, height: 300)
    outline.dataSource = rows
    outline.delegate = rows
    outline.reloadData()
    outline.expandItem(nil, expandChildren: true)
    scroll.layoutSubtreeIfNeeded()
    #expect(outline.numberOfRows == 2)
    #expect(outline.frame.width <= 240)
}

/// A view in a window: only what's on screen moves. Motion as asked for, whatever the Mac running the tests asks.
@MainActor func onScreen(_ view: NSView, in parent: NSView = NSView(), reduced: Bool = false) -> NSWindow {
    _ = NSApplication.shared
    Motion.pinned = reduced
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: [.titled], backing: .buffered, defer: true)
    window.contentView = parent
    parent.addSubview(view)
    view.frame = NSRect(x: 10, y: 10, width: 40, height: 16)
    return window
}

/// A number that grew rolls up: the old one drifts up as it fades, the new one comes up from below.
@MainActor @Test func aGrowingNumberRollsUp() {
    let parent = NSView(), label = NSTextField(labelWithString: "3")
    let window = onScreen(label, in: parent)
    defer { withExtendedLifetime(window) {} }
    label.roll(up: true)
    #expect(label.layer?.animation(forKey: "roll") != nil)
    let slide = label.layer?.animation(forKey: "slide") as? CABasicAnimation
    #expect(((slide?.fromValue as? NSValue)?.sizeValue.height ?? 0) < 0)   // from below: the window's y runs up
    let ghost = parent.subviews.first { $0 !== label }
    let drift = ghost?.layer?.animation(forKey: "drift") as? CABasicAnimation
    #expect(((drift?.toValue as? NSNumber)?.doubleValue ?? 0) > 0)
    #expect(drift?.duration == Motion.fast)   // what leaves goes sooner
}

/// Under Reduce Motion a number changes in place: nothing rolls, no picture is left behind.
@MainActor @Test func aNumberDoesntRollUnderReduceMotion() {
    let parent = NSView(), label = NSTextField(labelWithString: "3")
    let window = onScreen(label, in: parent, reduced: true)
    defer { withExtendedLifetime(window) {} }
    label.roll(up: true)
    #expect(label.layer?.animation(forKey: "roll") == nil)
    #expect(parent.subviews == [label])
}

/// An empty state fades as the list comes back rather than going at once, and one state crossfades into the next.
@MainActor @Test func anEmptyStateFadesOutAndIntoTheNext() {
    let empty = EmptyStateView()
    let window = onScreen(empty)
    defer { withExtendedLifetime(window) {} }
    empty.show("No Changes")
    empty.show("Git Isn't Available")
    #expect(empty.layer?.animation(forKey: kCATransition) != nil)
    empty.show(nil)
    #expect(!empty.showing)
    #expect(!empty.isHidden)   // still there, fading
    empty.show("No Changes")   // back before it went
    #expect(empty.showing && !empty.isHidden && empty.alphaValue == 1)
}

/// The button under a long, wrapped line sits in the middle with the rest of the block, not at its left edge.
@MainActor @Test func anEmptyStatesButtonIsCentred() {
    let empty = EmptyStateView(), area = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 400))
    let window = onScreen(NSView(), in: area)
    defer { withExtendedLifetime(window) {} }
    empty.place(in: area)
    area.layoutSubtreeIfNeeded()
    let button = NSButton(title: "Add Database…", target: nil, action: nil)
    empty.show(
        "No Databases", symbol: "cylinder",
        text:
            "Kelp looks in compose files, .env, config/database.yml, .idea and SQLite or DuckDB files of the project.",
        buttons: [button])
    area.layoutSubtreeIfNeeded()
    let frame = button.convert(button.bounds, to: empty)
    #expect(abs(frame.midX - empty.bounds.midX) < 1)
}

/// A closed tab's picture is gone in two thirds of the time its neighbours take to close over it.
@MainActor @Test func aGhostFadesOverWhatItIsGiven() {
    let parent = NSView(), tab = NSView()
    let window = onScreen(tab, in: parent)
    defer { withExtendedLifetime(window) {} }
    tab.leaveGhost(in: parent, duration: Motion.fast)
    let ghost = parent.subviews.first { $0 !== tab }
    #expect(ghost?.layer?.animation(forKey: "opacity")?.duration == Motion.fast)
}
