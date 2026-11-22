import AppKit
import DesignKit

/// The Mac's menus for the properties of the element chosen in Edit (`CanvasEditMode`, `CanvasEditBar`): the design
/// system's tokens first, the page's own values after, a swatch for a colour, ✓ on the one set, and Reset to the
/// page's own while it's changed. A choice goes back to the page (`kelpProps.set`), which writes it as a hand edit.
extension MarkdownTab {
    /// Handles `propMenu` and `retimeElement`. Returns false for another kind.
    func propsMessage(_ kind: String, _ body: [String: Any]) -> Bool {
        switch kind {
        case "propMenu":
            guard let key = body["key"] as? String, let items = body["items"] as? [[String: Any]] else { return true }
            propMenu(key, items, reset: body["reset"] as? Bool ?? false)
        case "retimeElement":
            guard let id = body["id"] as? String, let start = (body["start"] as? NSNumber)?.doubleValue,
                let length = (body["length"] as? NSNumber)?.doubleValue
            else { return true }
            retimeElement(id, start: start, length: max(length, 0.1))
        default: return false
        }
        return true
    }

    private func propMenu(_ key: String, _ items: [[String: Any]], reset: Bool) {
        let menu = NSMenu()
        let column = NSMenuItem.noteColumn(items.compactMap { $0["title"] as? String })
        var section: String?
        for item in items {
            guard let title = item["title"] as? String, let value = item["value"] as? String else { continue }
            if let next = item["section"] as? String, next != section {
                section = next
                if menu.numberOfItems > 0 { menu.addItem(.separator()) }
                menu.addItem(
                    .sectionHeader(
                        title: next == "tokens" ? String(localized: "Design System") : String(localized: "On the Page"))
                )
            }
            let made = menu.add(title) { [weak self] in
                self?.runJS("window.kelpProps?.set(\(Self.js(key)), \(Self.js(value)))")
            }
            if let detail = item["detail"] as? String, !detail.isEmpty {
                made.attributedTitle = NSMenuItem.titleWithNote(title, note: detail, column: column)
            }
            made.state = item["on"] as? Bool == true ? .on : .off
            if let swatch = (item["swatch"] as? String).flatMap(NSColor.init(css:)) { made.show(Self.swatch(swatch)) }
        }
        if reset {
            menu.addItem(.separator())
            menu.add(String(localized: "Back to the Page’s Own")) { [weak self] in
                self?.runJS("window.kelpProps?.set(\(Self.js(key)), null)")
            }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// A colour's square for a menu row.
    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let shape = NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: Metrics.radiusXS, yRadius: Metrics.radiusXS)
            color.setFill()
            shape.fill()
            NSColor.separatorColor.setStroke()
            shape.stroke()
            return true
        }
    }

    /// Moves or trims element `id` in time from its row in the column: a scene or a picture by its own times, an
    /// element by its animation's.
    private func retimeElement(_ id: String, start: Double, length: Double) {
        if let scene = motionStudio.scenes.first(where: { $0.id == id })
            ?? motionStudio.tracks.first(where: {
                $0.id == id && $0.delays.isEmpty
            })
        {
            var now = scene
            (now.start, now.length) = (start, length)
            return retime(scene: scene, as: now)
        }
        guard let track = motionStudio.tracks.first(where: { $0.id == id }) else { return }
        var now = track
        (now.start, now.length) = (start, track.delays.count == 1 ? length : track.length)
        retime(track, as: now)
    }
}

extension NSColor {
    /// A colour from `#rrggbb` (or `#rgb`), as the page names it; nil for anything else.
    convenience init?(css: String) {
        var hex = css.trimmingCharacters(in: .whitespaces)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat(value >> 16 & 0xff) / 255, green: CGFloat(value >> 8 & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}
