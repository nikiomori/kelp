import AppKit
import SwiftUI
import os

private let chosenAccent = OSAllocatedUnfairLock<NSColor?>(initialState: nil)

extension NSColor {
    /// 0xRRGGBB in sRGB.
    public convenience init(hex: Int, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// Parses "#rrggbb" or "rrggbb", as themes and Ghostty's config write colours, with two more digits for alpha. Nil
    /// for anything else.
    public convenience init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6 || digits.count == 8, let value = Int(digits, radix: 16) else { return nil }
        if digits.count == 8 {
            self.init(hex: value >> 8, alpha: CGFloat(value & 0xFF) / 255)
        } else {
            self.init(hex: value)
        }
    }

    /// "#rrggbb" in sRGB, as CSS and themes write it, for the colour as the current appearance has it.
    public var hexString: String {
        guard let srgb = usingColorSpace(.sRGB) else { return "#000000" }
        return String(
            format: "#%02x%02x%02x", Int((srgb.redComponent * 255).rounded()),
            Int((srgb.greenComponent * 255).rounded()),
            Int((srgb.blueComponent * 255).rounded()))
    }

    /// One colour in light appearances, another in dark.
    public static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    /// Status colours for text ("+6 −2", "1 needs you", M/U letters, an error under a field). The system colours are
    /// made for glyphs: as 11 pt text on a light sidebar, systemOrange is 2.1:1 and systemGreen 2.0:1, where text needs
    /// 4.5:1. Light appearances get darker shades (≥ 4.7:1 on the diff list's #E9E9E9). Dark appearances keep the
    /// system colours, except red and purple, which are lighter there. The orange is amber, so M and D don't both read
    /// red.
    public static let textOrange = dynamic(light: NSColor(hex: 0x9A5000), dark: .systemOrange)
    public static let textGreen = dynamic(light: NSColor(hex: 0x1C7332), dark: .systemGreen)
    public static let textRed = dynamic(light: NSColor(hex: 0xCC0014), dark: NSColor(hex: 0xFF6961))
    public static let textPurple = dynamic(light: NSColor(hex: 0x9C27B0), dark: NSColor(hex: 0xE07BFF))

    /// A git status letter's colour, as Files, Source Control and the diff show it: M amber, U and A green, D and !
    /// red, R and C the accent.
    public static func gitLetter(_ letter: String) -> NSColor {
        switch letter {
        case "!", "D": .textRed
        case "U", "A": .textGreen
        case "R", "C": .themeAccent
        default: .textOrange
        }
    }

    /// The accent, where a glyph or a count must read as the one with something to do (↑3 to push). With the Graphite
    /// accent it is the label's colour, because Graphite's grey came out lighter than the idle arrows beside it and
    /// looked disabled.
    public static let emphasis = NSColor(name: nil) { _ in
        (NSColor.themeAccent.usingColorSpace(.sRGB)?.saturationComponent ?? 1) < 0.1 ? .labelColor : .themeAccent
    }

    /// The accent colour in the chrome: the theme's accent, else the system's. Native controls keep the system's
    /// accent, which nothing can change.
    public static let themeAccent = NSColor(name: nil) { _ in chosenAccent.withLock { $0 } ?? .controlAccentColor }
    public static func setThemeAccent(_ color: NSColor?) { chosenAccent.withLock { $0 = color } }

    /// The three grey fills behind a control or a row: at rest (a field, a chip), under the pointer, and chosen. They
    /// are black in light appearances and white in dark. `labelColor.withAlphaComponent` is fixed to the appearance it
    /// was first read in (white, on a dark Mac), which left every fill invisible on a light theme.
    public static let fillRest = grey(0.05)
    public static let fillHover = grey(0.08)
    public static let fillSelected = grey(0.12)
    /// A card's fill in a colour someone picked: strong enough to tell apart, quiet enough for the text and marks on
    /// it. Ask for it while drawing, because it's fixed to the current appearance, as `labelColor.withAlphaComponent`
    /// is.
    public static func fillTint(_ color: NSColor) -> NSColor { color.withAlphaComponent(0.16) }
    /// Text offered and not yet put in (the editor's gray text): the text's own `color`, faded.
    public static func offered(_ color: NSColor) -> NSColor { color.withAlphaComponent(0.4) }
    /// A diff's fills: a whole added or removed line, the words changed in it (stronger), a hunk's header band, and the
    /// band of unchanged lines between hunks.
    public static let diffAdded = tint(.systemGreen, 0.14)
    public static let diffRemoved = tint(.systemRed, 0.14)
    public static let diffAddedWord = tint(.systemGreen, 0.32)
    public static let diffRemovedWord = tint(.systemRed, 0.32)
    public static let diffHunk = NSColor(name: nil) { _ in NSColor.themeAccent.withAlphaComponent(0.08) }
    public static let diffGap = tint(.quaternaryLabelColor, 0.06)
    /// A merge conflict's sides in the editor, as VS Code shows them: the current side as `diffAdded`, the incoming one
    /// blue.
    public static let conflictIncoming = tint(.systemBlue, 0.14)
    /// What an agent edited, in its work map: a file's block, and the lighter fill of a folder that holds an edit; the
    /// solid mark beside an edited file's name (`agentEditMark`). Blue, because amber is Source Control's "modified"
    /// and orange is kept for an agent that waits for you.
    public static let agentEditMark = NSColor.systemBlue
    public static let agentEdited = appearanceTint(.systemBlue, light: 0.38, dark: 0.55)
    public static let agentEditedFolder = appearanceTint(.systemBlue, light: 0.16, dark: 0.24)
    private static func appearanceTint(_ color: NSColor, light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var resolved = color
            appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) ?? color }
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return resolved.withAlphaComponent(isDark ? dark : light)
        }
    }
    /// `color` at `alpha`, read again in each appearance (`withAlphaComponent` alone keeps the appearance it was first
    /// read in).
    private static func tint(_ color: NSColor, _ alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var resolved = color
            appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) ?? color }
            return resolved.withAlphaComponent(alpha)
        }
    }
    /// A grey that is twice as strong with Increase Contrast (System Settings › Accessibility › Display), as the
    /// system's own fills get.
    private static func grey(_ alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let strong = fillAlpha(alpha, highContrast: increaseContrast)
            return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: strong) : NSColor(white: 0, alpha: strong)
        }
    }
    public static func fillAlpha(_ alpha: CGFloat, highContrast: Bool) -> CGFloat { highContrast ? 2 * alpha : alpha }
    /// Whether Increase Contrast is on, so what Kelp draws itself gets the edges and weight the system gives its own
    /// controls.
    public static var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
}

/// A git status letter in a word, for VoiceOver, which reads a bare "M" as a letter. It names the letters Files and
/// Source Control show, the ones `NSColor.gitLetter` colours. Nil for anything else (a folder's dot).
public func gitLetterWord(_ letter: String) -> String? {
    switch letter {
    case "M": String(localized: "Modified")
    case "A": String(localized: "Added")
    case "D": String(localized: "Deleted")
    case "R": String(localized: "Renamed")
    case "C": String(localized: "Copied")
    case "U": String(localized: "Untracked")
    case "!": String(localized: "Conflicted")
    default: nil
    }
}

/// The text shades for SwiftUI.
extension Color {
    public static let textOrange = Color(nsColor: .textOrange)
    public static let textGreen = Color(nsColor: .textGreen)
    public static let textRed = Color(nsColor: .textRed)
    public static let textPurple = Color(nsColor: .textPurple)
}
