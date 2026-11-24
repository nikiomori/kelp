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
        if selectKey(event) { return }
        if event.charactersIgnoringModifiers == "s",
            event.modifierFlags.isDisjoint(with: .deviceIndependentFlagsMask)
        {
            return onCut?("split", picked) ?? ()
        }
        guard let picked, [51, 117].contains(event.keyCode) else { return super.keyDown(with: event) }   // ⌫, ⌦
        onRemove?(picked)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "d": if let picked { onDuplicate?(picked) } else { return false }
        case "c" where selecting.ids.count > 1: onMany?("copy", Array(selecting.ids))
        case "x" where selecting.ids.count > 1: onMany?("cut", Array(selecting.ids))
        case "c": onCut?("copy", picked)
        case "x": onCut?("cut", picked)
        case "v": onCut?("paste", picked)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// A clip's menu: Split and Trim at the time, Duplicate and Delete; an empty stretch between scenes has Close Gap.
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        if let seam = seam(at: p) { return keyframing.seamMenu?(seam.out.id, seam.in.id) }
        if let key = keyframe(at: p) {
            keyframing.chosen = key
            needsDisplay = true
            return keyframing.menu?(key.id, key.at)
        }
        let lanes = rows
        for (lane, clips) in lanes.enumerated() {
            guard let clip = clips.first(where: { box($0, lane: lane).contains(p) }), !clip.id.isEmpty else { continue }
            picked = clip.id
            let menu = NSMenu()
            menu.add(String(localized: "Split at the Time"), key: "s") { [weak self] in
                self?.onCut?("split", clip.id)
            }
            .keyEquivalentModifierMask = []   // S alone, as the timeline takes it
            menu.add(String(localized: "Trim the Start to the Time")) { [weak self] in
                self?.onCut?("trimStart", clip.id)
            }
            menu.add(String(localized: "Trim the End to the Time")) { [weak self] in self?.onCut?("trimEnd", clip.id) }
            menu.addItem(.separator())
            menu.add(String(localized: "Duplicate"), key: "d") { [weak self] in self?.onDuplicate?(clip.id) }
            menu.addItem(.separator())
            menu.add(String(localized: "Delete")) { [weak self] in self?.onRemove?(clip.id) }
            return menu
        }
        if let gaps = gapMenu(at: p) { return gaps }
        let menu = NSMenu()
        menu.add(String(localized: "Subtitles from Text…")) { [weak self] in self?.onTypedCaptions?() }
        return menu
    }

    override func resetCursorRects() {
        let lanes = rows
        for (lane, clips) in lanes.enumerated() {
            for clip in clips where !clip.id.isEmpty && clip.trims { edges(box(clip, lane: lane)) }
        }
    }

    func edges(_ rect: NSRect) {
        addCursorRect(NSRect(x: rect.minX - 3, y: rect.minY, width: 6, height: rect.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: rect.maxX - 3, y: rect.minY, width: 6, height: rect.height), cursor: .resizeLeftRight)
    }
}
