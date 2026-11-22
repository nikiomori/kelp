import AppKit
import DesignKit

/// What the timeline takes besides the pointer: ⌫ and ⌘D on the clip clicked last, a clip's menu, and files dropped
/// from Finder.
extension MotionTimeline {
    override var acceptsFirstResponder: Bool { true }

    func files(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { files(sender).isEmpty ? [] : .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = files(sender), x = convert(sender.draggingLocation, from: nil).x
        guard !urls.isEmpty, x >= track.minX else { return false }
        onDropFiles?(urls, min(max(seconds(x), 0), length))
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let picked, [51, 117].contains(event.keyCode) else { return super.keyDown(with: event) }   // ⌫, ⌦
        onRemove?(picked)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let picked, event.modifierFlags.contains(.command),
            event.charactersIgnoringModifiers == "d"
        else { return super.performKeyEquivalent(with: event) }
        onDuplicate?(picked)
        return true
    }

    /// A clip's menu: Duplicate and Delete.
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let lanes = [scenes] + tracks.map { [$0] }
        for (lane, clips) in lanes.enumerated() {
            guard let clip = clips.first(where: { box($0, lane: lane).contains(p) }), !clip.id.isEmpty else { continue }
            picked = clip.id
            let menu = NSMenu()
            menu.add(String(localized: "Duplicate"), key: "d") { [weak self] in self?.onDuplicate?(clip.id) }
            menu.addItem(.separator())
            menu.add(String(localized: "Delete")) { [weak self] in self?.onRemove?(clip.id) }
            return menu
        }
        return nil
    }
}
