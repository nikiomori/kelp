import AppKit

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
        guard TextSize.design != .default, let d = font.fontDescriptor.withDesign(TextSize.design) else { return font }
        return NSFont(descriptor: d, size: 0) ?? font
    }
    public static func uiDigits(_ size: CGFloat, weight: Weight = .regular) -> NSFont {
        TextSize.design == .default ? .monospacedDigitSystemFont(ofSize: TextSize.of(size), weight: weight) : .ui(size, weight: weight)
    }
    /// Monospaced, for short machine text in the chrome (a command to run, a hash): `code-xs`.
    public static func uiMono(_ size: CGFloat, weight: Weight = .regular) -> NSFont { .monospacedSystemFont(ofSize: TextSize.of(size), weight: weight) }
}
