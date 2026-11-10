// The tab strip's parts: an item it shows, the capsule's buttons, a view's snapshot.
import AppKit
import Core
import DesignKit
import WorkbenchKit

extension TabStrip {
    struct Item: Equatable {
        let id: String
        var title: String
        var icon: NSImage?
        let toolTip: String?
        var edited = false
        /// A session's marks (its state, context ring, commands beside it), as its tab says them.
        var badge: TabBadge?
        /// A run's colour (the Run menu's): its tab glows so, steady, below any call for attention.
        var run: NSColor?
        /// An agent's tab: the sidebar's card for it under the pointer, in place of the tooltip.
        var card: SidebarItem.Kind?
        /// Its title ends with what tells it from a namesake ("README.md — docs"): it gives way in the middle, so that stays.
        var keepsEnd = false
    }
}

@MainActor
/// A button in a capsule: a soft fill fades in under the pointer, darkens held, springs when clicked (`PointerButton`).
final class CapsuleSegment: PointerButton {
    private var images: (pointed: NSImage?, atRest: NSImage?)?
    private var pointed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        imagePosition = .imageOnly
        radius = nil
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `image` under the pointer, `atRest` otherwise.
    func show(_ image: NSImage?, atRest: NSImage?) {
        images = (image, atRest)
        self.image = pointed ? image : atRest
    }
    private func follow(_ on: Bool) {
        pointed = on
        if let images { image = on ? images.pointed : images.atRest }
    }
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        follow(true)
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        follow(false)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        follow(false)
    }
}

extension NSView {
    /// What it shows now, as an image (a dragged tab or pane).
    func snapshot() -> NSImage {
        let img = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            img.addRepresentation(rep)
        }
        return img
    }
}
