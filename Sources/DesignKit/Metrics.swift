import AppKit

/// The design's sizes (tokens.json of the Kelp design system): rows and bars, insets, radii, durations. Rows and bars
/// that hold chrome text are measured for normal text: read them through `TextSize.of`.
public enum Metrics {
    // Bars
    public static let panelHeader: CGFloat = 36   // an inspector panel's bar
    public static let contentBar: CGFloat = 32    // a tab's toolbar (diff, Markdown, notebook, browser)
    public static let statusBar: CGFloat = 24     // under an editor tab

    // Rows
    public static let row: CGFloat = 24           // one line in the inspector
    public static let rowTwoLine: CGFloat = 38    // a name with a line under it
    public static let rowSection: CGFloat = 26    // a section's title over its rows
    public static let rowMenu: CGFloat = 30       // Quick Open, the switcher

    // Spacing
    public static let inset: CGFloat = 12         // a panel's edge to its content
    public static let insetTrailing: CGFloat = 8  // a bar's edge to its last icon
    public static let gap: CGFloat = 6            // between a bar's controls; icon to label in a row
    public static let gapWide: CGFloat = 8        // between independent controls in a tab's bar, a banner, a sheet's buttons
    public static let lineGap: CGFloat = 2        // between a row's two lines
    public static let emptyLift: CGFloat = 40     // an empty state sits this far over the middle
    public static let sheetInset: CGFloat = 20

    // Radii
    public static let radiusXS: CGFloat = 4       // chips, swatches
    public static let radiusSM: CGFloat = 6       // a row's selection, an icon button's hover
    public static let radiusMD: CGFloat = 8       // small controls floating in a tab (find bar)
    public static let radiusLG: CGFloat = 10      // the editor card, a banner, overlays inside a pane
    public static let radiusXL: CGFloat = 12      // floating panels (switcher, slide-out panel)

    // Icons
    public static let iconButton: CGFloat = 22    // an icon-only button's square
    public static let iconPoint: CGFloat = 13     // its symbol's point size
    public static let iconGap: CGFloat = 2        // between two icon buttons side by side

    // Popovers and sheets
    public static let popoverWidth: CGFloat = 300
    public static let sheetWidth: CGFloat = 480
}

/// How long things move, and nothing under Reduce Motion.
@MainActor
public enum Motion {
    public static let fast: TimeInterval = 0.15   // hover, icons moving, a banner coming in
    public static let base: TimeInterval = 0.2    // a panel sliding, Quick Open opening
    public static let slow: TimeInterval = 0.25   // a banner fading
    public static let appear: TimeInterval = 0.3  // a row coming in, the attention glow
    public static let disappear: TimeInterval = 0.4

    // A hover card: the pointer rests this long on a row (a card already up follows sooner); it closes this long after.
    public static let hoverOpen: TimeInterval = 0.5
    public static let hoverOpenWarm: TimeInterval = 0.12
    public static let hoverClose: TimeInterval = 0.2

    public static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// `d`, or 0 when the person asked for less motion.
    public static func duration(_ d: TimeInterval) -> TimeInterval { reduced ? 0 : d }
}
