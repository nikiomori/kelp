import AppKit
import DesignKit

/// Room under the cursor's line for a suggestion's further lines: the line holding `char` is laid out taller by
/// `height`, so the lines below move down rather than sit under the gray text.
final class GhostRoom: @unchecked Sendable {   // used on the main thread only, where the layout manager lays out
    var char: Int?
    var height: CGFloat = 0
}

/// Draws a suggestion's gray text over the editor: its first line from the cursor, the others from the line's start in
/// the room under it, and what the rest of the line held (closers) after its end, where ⇥ would put them.
final class GhostTextView: NSView {
    var lines: [String] = []
    var rest = ""
    /// Where the cursor is, from the view's left edge, and how tall a line is.
    var firstX: CGFloat = 0
    var lineHeight: CGFloat = 16
    var attributes: [NSAttributedString.Key: Any] = [:]
    var ghostColor = NSColor.tertiaryLabelColor, restColor = NSColor.labelColor
    /// Behind the text put in, for an edit offered (green); none for gray text.
    var tint: NSColor?
    /// What covers the rest of the line where it stood: the page, then the current line's tint.
    var cover: [NSColor] = []

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let ghost = attributes.merging([.foregroundColor: ghostColor]) { $1 }
        let top = CodeEditor.lineExtra / 2
        if !rest.isEmpty {
            let width = (rest as NSString).size(withAttributes: attributes).width
            for color in cover {
                color.setFill()
                NSRect(x: firstX, y: 0, width: width + 1, height: lineHeight).fill(using: .sourceOver)
            }
        }
        var lastEnd = firstX
        for (row, line) in lines.enumerated() {
            let x = row == 0 ? firstX : 0
            if let tint, !line.isEmpty {
                tint.setFill()
                let width = (line as NSString).size(withAttributes: ghost).width
                NSBezierPath(
                    roundedRect: NSRect(x: x, y: CGFloat(row) * lineHeight, width: width, height: lineHeight),
                    xRadius: 3, yRadius: 3
                ).fill()
            }
            (line as NSString).draw(at: NSPoint(x: x, y: CGFloat(row) * lineHeight + top), withAttributes: ghost)
            lastEnd = x + (line as NSString).size(withAttributes: ghost).width
        }
        let restAt = NSPoint(x: lastEnd, y: CGFloat(max(lines.count - 1, 0)) * lineHeight + top)
        (rest as NSString).draw(at: restAt, withAttributes: attributes.merging([.foregroundColor: restColor]) { $1 })
    }
}

extension CodeEditor {
    /// Shows `ghost`'s text at its place, or takes the gray text away.
    func showGhost(_ ghost: (text: String, at: Int)?) {
        suggestion.view = placeGhost(suggestion.view, ghost)
    }

    /// Draws `ghost`'s text at its place in `view` (made when there's none), in `color` on `tint` (gray on nothing when
    /// not given), making room under its line for its further lines; nil hides it. The room is one for both: gray text
    /// and an edit offered never show together.
    func placeGhost(
        _ existing: GhostTextView?, _ ghost: (text: String, at: Int)?, color: NSColor? = nil, tint: NSColor? = nil
    ) -> GhostTextView? {
        let tv = textView, room = tv.ghostRoom
        if let old = room.char {
            room.char = nil
            tv.relayOut(NSRange(location: min(old, tv.length), length: 0))
        }
        guard let ghost, let lm = tv.layoutManager else {
            existing?.isHidden = true
            return existing
        }
        let string = tv.string as NSString, font = tv.font ?? Self.font
        let lineStart = string.lineRange(for: NSRange(location: ghost.at, length: 0)).location
        let lineEnd = MultiCursor.lineEnd(string, ghost.at)
        let lines = ghost.text.components(separatedBy: "\n")
        let lineHeight = lm.defaultLineHeight(for: font) + Self.lineExtra
        // The line's last character carries the room: its line break, or its last character at the end of the text.
        let key = lineEnd < string.length ? lineEnd : lineEnd - 1
        if lines.count > 1, key >= lineStart {
            room.char = key
            room.height = CGFloat(lines.count - 1) * lineHeight
            tv.relayOut(NSRange(location: key, length: 1))
            lm.ensureLayout(forCharacterRange: NSRange(location: key, length: 1))
        }
        let view = existing ?? GhostTextView()
        if view.superview !== tv { tv.addSubview(view) }
        let caret = tv.caretRect(at: ghost.at)
        let left = tv.textContainerOrigin.x + (tv.textContainer?.lineFragmentPadding ?? 0)
        view.lines = lines
        view.rest = string.substring(with: NSRange(location: ghost.at, length: lineEnd - ghost.at))
        view.firstX = caret.minX - left
        view.lineHeight = lineHeight
        view.attributes = tv.typingAttributes
        let text = (tv.typingAttributes[.foregroundColor] as? NSColor) ?? .labelColor
        view.ghostColor = color ?? .offered(text)
        view.tint = tint
        view.restColor = text
        // Only the cursor's line wears the current line's tint.
        let cursorLine = string.lineRange(
            for: NSRange(location: min(tv.selectedRange().location, string.length), length: 0))
        view.cover = lineStart == cursorLine.location ? [tv.backgroundColor, tv.lineHighlight] : [tv.backgroundColor]
        view.frame = NSRect(
            x: left, y: caret.minY, width: max(tv.bounds.width - left, 1), height: CGFloat(lines.count) * lineHeight)
        view.isHidden = false
        view.needsDisplay = true
        return view
    }
}
