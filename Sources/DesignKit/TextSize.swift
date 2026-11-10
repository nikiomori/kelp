import AppKit
import SwiftUI

/// Settings › Appearance › Text size: larger text in the app's own chrome (sidebar, inspector, tabs, bars, popovers)
/// for people who want it; code (the terminal, the editor, a diff) has its own font size. Set as settings change, before
/// views that follow the setting hear of it: the sidebar redraws, the inspector's panels are rebuilt, the tabs retitle.
/// Limit: other views built before the change (a tab's toolbar and status bar) keep their size until they are built
/// again; following the setting there too means each tracking it.
@MainActor
public enum TextSize {
    public internal(set) static var scale: CGFloat = 1
    /// The theme's face for the chrome: the system font's own designs, so weights and sizes keep working.
    public internal(set) static var design = NSFontDescriptor.SystemDesign.default

    /// The chrome's sizes, named as the design system names them; `.ui(TextSize.row)`, not a number typed in.
    /// Text in a panel, a sheet, a popover: 13.
    public nonisolated static let body: CGFloat = 13
    /// A list row's title, a field: 12.
    public nonisolated static let row: CGFloat = 12
    /// Secondary text, a section title, a row's second line, a count: 11.
    public nonisolated static let caption: CGFloat = 11
    /// A badge's letters, the smallest text: 10.
    public nonisolated static let micro: CGFloat = 10

    public static func apply(_ name: String?) { scale = ["large": 1.15, "larger": 1.3][name ?? ""] ?? 1 }
    public static func apply(design name: String?) {
        design = ["mono": .monospaced, "serif": .serif, "rounded": .rounded][name ?? ""] ?? .default
    }

    /// A row or spacing measured for normal text, at this size.
    public static func of(_ points: CGFloat) -> CGFloat { (points * scale).rounded() }
}

@MainActor
extension NSFont {
    /// The system font at `size` for normal text, scaled by the text-size setting.
    public static func ui(_ size: CGFloat, weight: Weight = .regular) -> NSFont {
        let font = NSFont.systemFont(ofSize: TextSize.of(size), weight: weight)
        guard TextSize.design != .default, let descriptor = font.fontDescriptor.withDesign(TextSize.design) else {
            return font
        }
        return NSFont(descriptor: descriptor, size: 0) ?? font
    }
    public static func uiDigits(_ size: CGFloat, weight: Weight = .regular) -> NSFont {
        TextSize.design == .default
            ? .monospacedDigitSystemFont(ofSize: TextSize.of(size), weight: weight) : .ui(size, weight: weight)
    }
    /// Monospaced, for short machine text in the chrome (a command to run, a hash): `code-xs`.
    public static func uiMono(_ size: CGFloat, weight: Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: TextSize.of(size), weight: weight)
    }
}

/// The same fonts for SwiftUI views, so they follow Text size and the look's font too.
@MainActor
extension Font {
    public static func ui(_ size: CGFloat, weight: NSFont.Weight = .regular) -> Font {
        Font(NSFont.ui(size, weight: weight) as CTFont)
    }
    public static func uiMono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> Font {
        Font(NSFont.uiMono(size, weight: weight) as CTFont)
    }
    /// An `Image(systemName:)` beside chrome text: the symbols' one weight at a size from Metrics.
    public static func symbol(_ size: CGFloat = Metrics.iconPoint) -> Font { .ui(size, weight: Metrics.iconWeight) }
}

@MainActor
extension View {
    /// A section's title over its rows: 11 semibold, secondary. One look for every titled section.
    public func sectionTitle() -> some View {
        font(.ui(TextSize.caption, weight: .semibold)).foregroundStyle(.secondary)
    }
    /// A section's title in a column of sections: `sectionTitle()` at the bottom of a section row's height.
    public func sectionHeading() -> some View { sectionTitle().frame(height: Metrics.rowSection, alignment: .bottom) }
    /// A line that says there's nothing here or why: 12, secondary.
    public func quietNote() -> some View { font(.ui(TextSize.row)).foregroundStyle(.secondary) }
}
