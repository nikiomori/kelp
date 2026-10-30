import AppKit
import SwiftUI

extension NSColor {
    /// 0xRRGGBB in sRGB.
    public convenience init(hex: Int, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// "#rrggbb" or "rrggbb", as themes and Ghostty's config write colours; nil for anything else.
    public convenience init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        self.init(hex: v)
    }

    /// "#rrggbb" in sRGB, as CSS and themes write it (the colour as the current appearance has it).
    public var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02x%02x%02x", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }

    /// One colour in light appearances, another in dark.
    public static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    /// Status colours for text ("+6 −2", "1 needs you", M/U letters, an error under a field). The system ones are made for
    /// glyphs: as 11 pt text on a light sidebar systemOrange is 2.1:1 and systemGreen 2.0:1, where text needs 4.5:1. Light
    /// appearances get darker shades (≥ 4.7:1 on the diff list's #E9E9E9); dark keeps the system colours, except red and
    /// purple, which are lighter there.
    public static let textOrange = dynamic(light: NSColor(hex: 0x9A5000), dark: .systemOrange)   // amber, so M and D don't both read red
    public static let textGreen = dynamic(light: NSColor(hex: 0x1C7332), dark: .systemGreen)
    public static let textRed = dynamic(light: NSColor(hex: 0xCC0014), dark: NSColor(hex: 0xFF6961))
    public static let textPurple = dynamic(light: NSColor(hex: 0x9C27B0), dark: NSColor(hex: 0xE07BFF))

    /// A git status letter's colour, as Files, Source Control and the diff show it: M amber, U and A green, D and ! red,
    /// R and C the accent.
    public static func gitLetter(_ l: String) -> NSColor {
        switch l {
        case "!", "D": .textRed
        case "U", "A": .textGreen
        case "R", "C": .controlAccentColor
        default: .textOrange
        }
    }

    /// The accent where a glyph or a count must read as the one with something to do (↑3 to push): the label's colour
    /// when the accent is Graphite, whose grey came out lighter than the idle arrows beside it and looked disabled.
    public static let emphasis = NSColor(name: nil) { _ in
        (NSColor.controlAccentColor.usingColorSpace(.sRGB)?.saturationComponent ?? 1) < 0.1 ? .labelColor : .controlAccentColor
    }

    /// The three grey fills behind a control or a row: at rest (a field, a chip), under the pointer, chosen. Black in
    /// light appearances, white in dark: `labelColor.withAlphaComponent` is fixed to the appearance it was first read in
    /// (white, on a dark Mac), which left every fill invisible on a light theme.
    public static let fillRest = grey(0.05)
    public static let fillHover = grey(0.08)
    public static let fillSelected = grey(0.12)
    /// A card's fill in a colour someone picked: strong enough to tell apart, quiet enough for the text and marks on it.
    /// Ask for it while drawing, it's fixed to the current appearance as `labelColor.withAlphaComponent` is.
    public static func fillTint(_ color: NSColor) -> NSColor { color.withAlphaComponent(0.16) }
    /// A card's glow where it's strongest, at its edge, fading to nothing; for reading while drawing too.
    public static func fillGlow(_ color: NSColor) -> NSColor {
        color.withAlphaComponent(NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.3 : 0.2)
    }
    private static func grey(_ alpha: CGFloat) -> NSColor { dynamic(light: NSColor(white: 0, alpha: alpha), dark: NSColor(white: 1, alpha: alpha)) }
}

/// The text shades for SwiftUI.
extension Color {
    public static let textOrange = Color(nsColor: .textOrange)
    public static let textGreen = Color(nsColor: .textGreen)
    public static let textRed = Color(nsColor: .textRed)
    public static let textPurple = Color(nsColor: .textPurple)
}
