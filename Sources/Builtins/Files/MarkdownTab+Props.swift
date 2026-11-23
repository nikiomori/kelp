import AppKit
import Core
import DesignKit
import KelpKit
import UniformTypeIdentifiers

/// The Mac's menus for the properties of the element chosen in Edit (`CanvasEditMode`, `CanvasEditBar`): the design
/// system's tokens first, the page's own values after, a swatch for a colour, ✓ on the one set, and Reset to the
/// page's own while it's changed. A choice goes back to the page (`kelpProps.set`), which writes it as a hand edit.
extension MarkdownTab {
    /// Handles `propMenu` and `retimeElement`. Returns false for another kind.
    func propsMessage(_ kind: String, _ body: [String: Any]) -> Bool {
        switch kind {
        case "propMenu":
            guard let key = body["key"] as? String, let items = body["items"] as? [[String: Any]] else { return true }
            propMenu(
                key, items, reset: body["reset"] as? Bool ?? false,
                element: (body["board"] as? String).flatMap { b in (body["id"] as? String).map { (b, $0) } })
        case "retimeElement":
            guard let id = body["id"] as? String, let start = (body["start"] as? NSNumber)?.doubleValue,
                let length = (body["length"] as? NSNumber)?.doubleValue
            else { return true }
            retimeElement(id, start: start, length: max(length, 0.1))
        default: return false
        }
        return true
    }

    private func propMenu(_ key: String, _ items: [[String: Any]], reset: Bool, element: (String, String)?) {
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
        if key == "font", let element { fontItems(menu, element) }
        if reset {
            menu.addItem(.separator())
            menu.add(String(localized: "Back to the Page’s Own")) { [weak self] in
                self?.runJS("window.kelpProps?.set(\(Self.js(key)), null)")
            }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// The Mac's fonts, each drawn in itself, and Add Font… to bring a file of one into the page.
    private func fontItems(_ menu: NSMenu, _ element: (board: String, id: String)) {
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        let mac = NSMenu()
        for family in NSFontManager.shared.availableFontFamilies where !family.hasPrefix(".") {
            let item = mac.add(family) { [weak self] in self?.useMacFont(family, element) }
            if let face = NSFont(name: family, size: NSFont.systemFontSize) {
                item.attributedTitle = NSAttributedString(string: family, attributes: [.font: face])
            }
        }
        menu.addItem(withTitle: String(localized: "On This Mac"), action: nil, keyEquivalent: "").submenu = mac
        menu.add(String(localized: "Add Font…")) { [weak self] in self?.addFont(element) }
    }

    /// A font of this Mac on the element. One the user put on this Mac (not one macOS brings) is copied beside the page
    /// first, so the page keeps it elsewhere.
    private func useMacFont(_ family: String, _ element: (board: String, id: String)) {
        let file = NSFontManager.shared.availableMembers(ofFontFamily: family)?.first?.first as? String
        let url = file.flatMap {
            CTFontDescriptorCopyAttribute(CTFontDescriptorCreateWithNameAndSize($0 as CFString, 0), kCTFontURLAttribute)
                as? URL
        }
        if let url, !url.path.hasPrefix("/System/") {
            Task { await bringFont(url, family: family, element) }
            return
        }
        runJS("window.kelpProps?.set('font', \(Self.js("'\(family)'")))")
    }

    /// Asks for a font file and brings it into the page.
    private func addFont(_ element: (board: String, id: String)) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["ttf", "otf", "woff", "woff2"].compactMap { UTType(filenameExtension: $0) }
        panel.beginSheetModal(for: window) { [weak self] answer in
            guard answer == .OK, let file = panel.url else { return }
            let family = file.deletingPathExtension().lastPathComponent
            Task { @MainActor in await self?.bringFont(file, family: family, element) }
        }
    }

    /// Copies font `file` beside the page, adds its @font-face, and sets the element's font to it.
    private func bringFont(_ file: URL, family: String, _ element: (board: String, id: String)) async {
        let folder = url.deletingLastPathComponent().path
        guard let copied = await app.call(FilesCopy(paths: [file.path], into: folder)) else { return }
        guard let path = copied.made.first else {
            return Banner.show(copied.error ?? String(localized: "Couldn’t copy the font."), style: .error)
        }
        let name = (path as NSString).lastPathComponent
        let edit = { (_: String) in HandEdit(board: element.board, id: element.id, what: "font", from: nil, to: family)
        }
        rewrite(element.board, edit: edit) { source in
            BoardEdit.addFontFace(source, family: family, file: name).flatMap {
                BoardEdit.setStyle($0, id: element.id, property: "font-family", value: "'\(family)'")
            }
        }
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
