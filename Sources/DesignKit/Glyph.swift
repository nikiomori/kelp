import AppKit

/// Kelp's own line drawings, as the design has them, in place of the SF Symbols of the same names: git's branch and
/// pull request with their commits as rings, a list with rings, CI's check in a ring, the window's buttons and the
/// Settings sections. `NSImage.symbol` and `SymbolIcon` hand them out under the names they replace, so every use
/// (inspector, window bar, menus, Settings) gets them. They are SVG path data on a 16-point grid, stroked with
/// 1.3-point round lines and never filled, as templates, so they tint as symbols do. The same data draws them on the
/// design canvas, so what was picked there is what Kelp draws.
public enum Glyph {
    public static func image(_ name: String, size: CGFloat) -> NSImage? {
        guard let data = shapes[name] else { return nil }
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let path = NSBezierPath(svg: data)
            path.transform(using: AffineTransform(scale: rect.width / 16))
            path.lineWidth = 1.3 * rect.width / 16
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }

    static let shapes: [String: String] = [
        // Source control: a branch leaving the trunk.
        "arrow.triangle.branch": """
        M2.5 3.5a1.5 1.5 0 1 0 3 0a1.5 1.5 0 1 0 -3 0zM2.5 12.5a1.5 1.5 0 1 0 3 0a1.5 1.5 0 1 0 -3 0zM10.5 5
        a1.5 1.5 0 1 0 3 0a1.5 1.5 0 1 0 -3 0zM4 5v6M12 6.5C12 9.5 4 8.5 4 11
        """,
        // A pull request: the branch's commit coming back to the trunk.
        "arrow.triangle.pull": """
        M2.5 3.5a1.5 1.5 0 1 0 3 0a1.5 1.5 0 1 0 -3 0zM2.5 12.5a1.5 1.5 0 1 0 3 0a1.5 1.5 0 1 0 -3 0z
        M10.5 12.5a1.5 1.5 0 1 0 3 0a1.5 1.5 0 1 0 -3 0zM4 5v6M12 11V6.5C12 5.4 11.1 4.5 10 4.5H7.5
        M9 3 7.5 4.5 9 6
        """,
        // Issues and pull requests: a list.
        "checklist": """
        M2 4.5a1.5 1.5 0 1 0 3 0a1.5 1.5 0 1 0 -3 0zM2 11.5a1.5 1.5 0 1 0 3 0a1.5 1.5 0 1 0 -3 0zM7 4.5h7
        M7 11.5h7
        """,
        // CI: a check in a ring.
        "checkmark.seal": "M2 8a6 6 0 1 0 12 0a6 6 0 1 0 -12 0zM5.5 8l2 2 3-4",
        // Activity: a gauge.
        "gauge.with.dots.needle.33percent": """
        M2 8a6 6 0 1 0 12 0a6 6 0 1 0 -12 0zM8 8l3-3M7.4 8a0.6 0.6 0 1 0 1.2 0a0.6 0.6 0 1 0 -1.2 0z
        """,
        // The sidebars.
        "sidebar.left": """
        M4 2.5h8a2.5 2.5 0 0 1 2.5 2.5v6a2.5 2.5 0 0 1 -2.5 2.5h-8a2.5 2.5 0 0 1 -2.5 -2.5v-6
        a2.5 2.5 0 0 1 2.5 -2.5zM6 2.5v11
        """,
        "sidebar.right": """
        M4 2.5h8a2.5 2.5 0 0 1 2.5 2.5v6a2.5 2.5 0 0 1 -2.5 2.5h-8a2.5 2.5 0 0 1 -2.5 -2.5v-6
        a2.5 2.5 0 0 1 2.5 -2.5zM10 2.5v11
        """,
        // Chats: a speech bubble.
        "bubble.left": """
        M4 2.5h8a2.5 2.5 0 0 1 2.5 2.5v4a2.5 2.5 0 0 1-2.5 2.5H7l-3 2.5v-2.5a2.5 2.5 0 0 1-2.5-2.5V5
        A2.5 2.5 0 0 1 4 2.5z
        """,
        // Files, and Add Project.
        "folder": """
        M1.5 4.5A1.5 1.5 0 0 1 3 3h3l1.5 1.5h5.5a1.5 1.5 0 0 1 1.5 1.5v6a1.5 1.5 0 0 1-1.5 1.5H3
        a1.5 1.5 0 0 1-1.5-1.5z
        """,
        "folder.badge.plus": """
        M1.5 4.5A1.5 1.5 0 0 1 3 3h3l1.5 1.5h5.5a1.5 1.5 0 0 1 1.5 1.5v6a1.5 1.5 0 0 1-1.5 1.5H3
        a1.5 1.5 0 0 1-1.5-1.5zM8 7v4M6 9h4
        """,
        // Settings: a cog with eight teeth.
        "gearshape": """
        M12.8 7.03L14.25 7.18L14.25 8.82L12.8 8.97L12.08 10.71L12.99 11.84L11.84 12.99L10.71 12.08L8.97 12.8
        L8.82 14.25L7.18 14.25L7.03 12.8L5.29 12.08L4.16 12.99L3.01 11.84L3.92 10.71L3.2 8.97L1.75 8.82
        L1.75 7.18L3.2 7.03L3.92 5.29L3.01 4.16L4.16 3.01L5.29 3.92L7.03 3.2L7.18 1.75L8.82 1.75L8.97 3.2
        L10.71 3.92L11.84 3.01L12.99 4.16L12.08 5.29zM6 8a2 2 0 1 0 4 0a2 2 0 1 0 -4 0z
        """,
        // Appearance: a brush and its stroke.
        "paintpalette": """
        M14 1.5 9.5 6M9.5 6c-1.5-.5-3 .3-3 1.8 0 1.2-.8 2-1.9 2.4 2.2.5 5-.3 4.9-2.6zM2 14.2c2-1.2 4 1.2 6 0
        s4 1.2 6 0
        """,
        // Agents: a big star and a small one.
        "sparkles": """
        M6.5 5
        c0 2.47 2.03 4.5 4.5 4.5-2.47 0-4.5 2.03-4.5 4.5 0-2.47-2.03-4.5-4.5-4.5 2.47 0 4.5-2.03 4.5-4.5z
        M12.5 1.5c0 1.1 0.9 2 2 2-1.1 0-2 0.9-2 2 0-1.1-0.9-2-2-2 1.1 0 2-0.9 2-2z
        """,
        // Agent Catalog.
        "square.grid.2x2": """
        M3.5 2h2a1.5 1.5 0 0 1 1.5 1.5v2a1.5 1.5 0 0 1 -1.5 1.5h-2a1.5 1.5 0 0 1 -1.5 -1.5v-2
        a1.5 1.5 0 0 1 1.5 -1.5zM10.5 2h2a1.5 1.5 0 0 1 1.5 1.5v2a1.5 1.5 0 0 1 -1.5 1.5h-2
        a1.5 1.5 0 0 1 -1.5 -1.5v-2a1.5 1.5 0 0 1 1.5 -1.5zM3.5 9h2a1.5 1.5 0 0 1 1.5 1.5v2
        a1.5 1.5 0 0 1 -1.5 1.5h-2a1.5 1.5 0 0 1 -1.5 -1.5v-2a1.5 1.5 0 0 1 1.5 -1.5zM10.5 9h2
        a1.5 1.5 0 0 1 1.5 1.5v2a1.5 1.5 0 0 1 -1.5 1.5h-2a1.5 1.5 0 0 1 -1.5 -1.5v-2a1.5 1.5 0 0 1 1.5 -1.5
        z
        """,
        // Notifications.
        "bell": "M4 11V7a4 4 0 0 1 8 0v4l1.5 1.5h-11zM6.5 14.5h3",
        // Phone.
        "iphone": "M6.5 1.5h3a2 2 0 0 1 2 2v9a2 2 0 0 1 -2 2h-3a2 2 0 0 1 -2 -2v-9a2 2 0 0 1 2 -2zM7 12h2",
        // Terminal.
        "terminal": """
        M4 2.5h8a2.5 2.5 0 0 1 2.5 2.5v6a2.5 2.5 0 0 1 -2.5 2.5h-8a2.5 2.5 0 0 1 -2.5 -2.5v-6
        a2.5 2.5 0 0 1 2.5 -2.5zM4.5 6l2 2-2 2M8.5 10h3
        """,
        // Editor: a page of text.
        "doc.text": """
        M5.5 1.5h5a2 2 0 0 1 2 2v9a2 2 0 0 1 -2 2h-5a2 2 0 0 1 -2 -2v-9a2 2 0 0 1 2 -2zM6 5.5h4M6 8h4M6 10.5
        h2.5
        """,
        // Artifacts: a page with a picture over its text.
        "doc.richtext": """
        M5.5 1.5h5a2 2 0 0 1 2 2v9a2 2 0 0 1 -2 2h-5a2 2 0 0 1 -2 -2v-9a2 2 0 0 1 2 -2zM6.5 4h3
        a0.75 0.75 0 0 1 0.75 0.75v2a0.75 0.75 0 0 1 -0.75 0.75h-3a0.75 0.75 0 0 1 -0.75 -0.75v-2
        a0.75 0.75 0 0 1 0.75 -0.75zM6 10h4M6 12h2.5
        """,
        // Languages.
        "curlybraces": """
        M6 2.5c-1.5 0-2 .5-2 2V6c0 1-.5 2-1.5 2 1 0 1.5 1 1.5 2v1.5c0 1.5.5 2 2 2M10 2.5c1.5 0 2 .5 2 2V6
        c0 1 .5 2 1.5 2-1 0-1.5 1-1.5 2v1.5c0 1.5-.5 2-2 2
        """,
        // Databases.
        "cylinder.split.1x2": """
        M3 4a5 2 0 1 0 10 0a5 2 0 1 0 -10 0zM3 4v8c0 1.1 2.2 2 5 2s5-.9 5-2V4M3 8c0 1.1 2.2 2 5 2s5-.9 5-2
        """,
        // Integrations.
        "link": """
        M7 9a2.5 2.5 0 0 0 3.5 0L13 6.5A2.5 2.5 0 0 0 9.5 3L8.5 4M9 7a2.5 2.5 0 0 0-3.5 0L3 9.5
        A2.5 2.5 0 0 0 6.5 13l1-1
        """,
        // Keyboard.
        "command": """
        M6 6H4.5A1.5 1.5 0 1 1 6 4.5v7A1.5 1.5 0 1 1 4.5 10h7a1.5 1.5 0 1 1-1.5 1.5v-7A1.5 1.5 0 1 1 11.5 6z
        """,
        // Skills & MCP: a plug.
        "powerplug": "M6 2v3.3M10 2v3.3M4 5.3h8V8a4 4 0 0 1-8 0zM8 12v2",
        // Sound.
        "waveform": "M2 7v2M4.5 5v6M7 2.5v11M9.5 5.5v5M12 4v8M14 7v2",
        // A server.
        "server.rack": """
        M3.5 2.5h9a1.5 1.5 0 0 1 1.5 1.5v1.5a1.5 1.5 0 0 1 -1.5 1.5h-9a1.5 1.5 0 0 1 -1.5 -1.5v-1.5
        a1.5 1.5 0 0 1 1.5 -1.5zM3.5 9h9a1.5 1.5 0 0 1 1.5 1.5v1.5a1.5 1.5 0 0 1 -1.5 1.5h-9
        a1.5 1.5 0 0 1 -1.5 -1.5v-1.5a1.5 1.5 0 0 1 1.5 -1.5zM4.5 4.75h.01M4.5 11.25h.01
        """,
        // Extensions: a puzzle piece.
        "puzzlepiece.extension": "M2.5 5h3a1.5 1.5 0 1 1 3 0h3v2.5a1.5 1.5 0 1 1 0 3V13.5h-9z"
    ]
}

/// SF Symbol image helper used by tabs and menus; the names Kelp draws itself get its own drawing (Glyph).
/// `size` is the point size of the symbol it stands for, as the view's `symbolConfiguration` gives it: a view sizes
/// an SF Symbol by that, but a drawing only by its own size, so a glyph is made 3 pt over it (as `SymbolIcon` does).
/// At one size for all, the terminal glyph stood 17 points wide in a row's 11-point chip.
/// It keeps one image per name, label and size, because an image equals only itself, so a fresh one on every call
/// made each tab, chip and row icon look changed on every session event (the tab strip's "nothing changed" check
/// never held).
extension NSImage {
    public static func symbol(_ name: String, _ label: String? = nil, size: CGFloat = Metrics.iconPoint) -> NSImage {
        let key = "\(name)\u{0}\(label ?? "")\u{0}\(size)" as NSString
        if let known = symbolCache.object(forKey: key) { return known }
        let made =
            Glyph.image(name, size: size + 3).map { glyph in
                glyph.accessibilityDescription = label
                return glyph
            }
            ?? NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()
        symbolCache.setObject(made, forKey: key)
        return made
    }
}
extension NSAttributedString {
    /// A count with its sign before it, as a branch's ↓3 and ↑37: the action's own symbol, then the number 2 pt after
    /// it in digits of one width, both in `color`. Whatever says how many commits wait to be pulled or pushed writes
    /// it with this (the title bar's chip, Source Control's header and its button), so the arrow is one drawing at
    /// every text size. Typed as "↑" it was the font's own arrow, another one at each size and in each theme's font.
    /// With no count it is the arrow alone, the same one: a button with nothing to move.
    @MainActor public static func signed(_ symbol: String, _ count: Int?, size: CGFloat, color: NSColor)
        -> NSAttributedString
    {
        let font = NSFont.uiDigits(size, weight: .semibold), text = NSMutableAttributedString()
        // The arrow is as heavy as the digits beside it, not the chrome's medium, which read as a hairline there.
        let arrow = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Metrics.iconTiny, weight: .semibold))
        if let arrow {
            let sign = NSTextAttachment()
            sign.image = arrow
            // On the digits' middle: an attachment stands on the baseline otherwise, half a line too high.
            sign.bounds = NSRect(origin: NSPoint(x: 0, y: (font.capHeight - arrow.size.height) / 2), size: arrow.size)
            text.append(NSAttributedString(attachment: sign))
            if count != nil { text.addAttribute(.kern, value: 2, range: NSRange(location: 0, length: text.length)) }
        }
        if let count { text.append(NSAttributedString(string: "\(count)")) }
        text.addAttributes([.font: font, .foregroundColor: color], range: NSRange(location: 0, length: text.length))
        return text
    }
}
// NSCache is thread-safe, and the images handed out aren't changed.
nonisolated(unsafe) private let symbolCache = NSCache<NSString, NSImage>()
