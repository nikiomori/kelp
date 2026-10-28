import AppKit

/// Settings › Appearance › Interface text: larger text in the app's own chrome (sidebar, inspector, tabs, bars, popovers)
/// for people who want it; code (the terminal, the editor, a diff) has its own font size. Set as settings change, before
/// views that follow the setting hear of it: the sidebar redraws and the inspector's panels are rebuilt.
@MainActor
public enum TextSize {
    public internal(set) static var scale: CGFloat = 1

    public static func apply(_ name: String?) { scale = ["large": 1.15, "larger": 1.3][name ?? ""] ?? 1 }

    /// A row or spacing measured for normal text, at this size.
    public static func of(_ points: CGFloat) -> CGFloat { (points * scale).rounded() }
}

@MainActor
extension NSFont {
    /// The system font at `size` for normal text, scaled by the text-size setting.
    public static func ui(_ size: CGFloat, weight: Weight = .regular) -> NSFont { .systemFont(ofSize: TextSize.of(size), weight: weight) }
    public static func uiDigits(_ size: CGFloat, weight: Weight = .regular) -> NSFont { .monospacedDigitSystemFont(ofSize: TextSize.of(size), weight: weight) }
    /// Monospaced, for short machine text in the chrome (a command to run, a hash): `code-xs`.
    public static func uiMono(_ size: CGFloat, weight: Weight = .regular) -> NSFont { .monospacedSystemFont(ofSize: TextSize.of(size), weight: weight) }
}
