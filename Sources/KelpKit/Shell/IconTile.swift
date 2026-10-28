import AppKit
import CoreImage
import Core
import DesignKit

/// The small rounded tiles agents and projects show as (sidebar, tabs, menus), so every row's icon has the same size
/// and shape: an app's icon filling its tile without the margin macOS draws around it, or the name's initial on a colour.
@MainActor
enum IconTile {
    nonisolated static let side: CGFloat = 32

    /// A Mac app's icon cropped to its body: on the Big Sur grid the body is 824 of the 1024-point canvas.
    static func app(_ icon: NSImage) -> NSImage {
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).addClip()
            let grow = r.width * (1024.0 / 824.0 - 1) / 2
            icon.draw(in: r.insetBy(dx: -grow, dy: -grow))
            NSGraphicsContext.restoreGraphicsState()
            edge(r)
            return true
        }
        img.cacheMode = .never   // its edge is drawn for each appearance
        return img
    }

    /// A hairline just inside a tile's edge, so every tile has one: a black logo's on a dark row and a white one's on a
    /// light row read as tiles of the same shape, not as a loose mark beside bright squares.
    static func edge(_ r: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.14).setStroke()
        let line = NSBezierPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), xRadius: 6.75, yRadius: 6.75)
        line.lineWidth = 0.5
        line.stroke()
    }

    /// A tile for a name: with `color`, its initial in white on that colour (an agent's brand); otherwise its initials
    /// ("AS" for AgroStorage) in a quiet hue on a tint of it, picked from the name (the same name, the same hue). The
    /// hues leave out orange, red and green: next to a row's status marks those mean asking, failed and done.
    static func letter(_ name: String, color: NSColor? = nil, size: CGFloat = side) -> NSImage {
        let text = color == nil ? initials(name) : name.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "?"
        let hue = hues[name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % hues.count]
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            (color ?? hue.tint(dark)).setFill()
            NSBezierPath(roundedRect: r, xRadius: r.width * 7 / 32, yRadius: r.height * 7 / 32).fill()
            let s = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: r.height * (text.count > 1 ? 0.5 : 0.62), weight: .bold),
                .foregroundColor: color == nil ? hue.ink(dark) : NSColor.white
            ])
            let b = s.size()
            s.draw(at: NSPoint(x: r.midX - b.width / 2, y: r.midY - b.height / 2))
            return true
        }
        img.cacheMode = .never   // drawn again for each appearance: one cached tile serves light and dark rows
        img.accessibilityDescription = name
        return img
    }

    /// The first letters of the first two words: "AgroStorage" AS, "kelp-extensions" KE, "vangersert" V.
    static func initials(_ name: String) -> String {
        var words: [String] = [], word = ""
        for c in name {
            let starts = c.isUppercase && word.last?.isLowercase == true   // camelCase
            if !(c.isLetter || c.isNumber) || starts { if !word.isEmpty { words.append(word) }; word = "" }
            if c.isLetter || c.isNumber { word.append(c) }
        }
        if !word.isEmpty { words.append(word) }
        let lettered = words.filter { $0.first?.isLetter == true }
        let out = (lettered.isEmpty ? words : lettered).prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
        return out.isEmpty ? "?" : out
    }

    /// A tile's hue in both appearances: its letter (≥ 4.5:1 on its tint) and the tint under it.
    private struct Hue {
        let dark: Int, light: Int, gray: Bool
        func ink(_ dark: Bool) -> NSColor {
            NSColor(hex: dark ? self.dark : light)
        }
        func tint(_ dark: Bool) -> NSColor {
            gray ? (dark ? NSColor.white.withAlphaComponent(0.1) : NSColor.black.withAlphaComponent(0.08))
                : ink(dark).withAlphaComponent(dark ? 0.18 : 0.14)
        }
    }
    private static let hues = [Hue(dark: 0x6CB4FF, light: 0x0058B8, gray: false), Hue(dark: 0x9E9CFF, light: 0x4440C0, gray: false),
                               Hue(dark: 0xD59CFF, light: 0x8A2BB0, gray: false), Hue(dark: 0x5BD6E6, light: 0x006473, gray: false),
                               Hue(dark: 0xD2AE88, light: 0x7A5230, gray: false), Hue(dark: 0xC7C7CC, light: 0x48484A, gray: true)]
}

extension NSImage {
    /// The same picture without its colour, at the same size (a paused agent's icon).
    var grayscale: NSImage {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return self }
        let gray = CIImage(cgImage: cg).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        let out = NSImage(size: size)
        out.addRepresentation(NSCIImageRep(ciImage: gray))
        return out
    }
}

extension NSImage {
    /// A copy drawn at `side` points square.
    func resized(_ side: CGFloat) -> NSImage {
        let img = copy() as? NSImage ?? self
        img.size = NSSize(width: side, height: side)
        return img
    }
}

extension FileChange {
    /// VS Code's status letter and colour, as Files and the diff's file list show it (text shades: they colour names too).
    package var badge: (String, NSColor) {
        let l = conflicted ? "!" : untracked ? "U" : (index == "D" || worktree == "D") ? "D" : index == "A" ? "A" : index == "R" ? "R" : "M"
        return (l, .gitLetter(l))
    }
}
