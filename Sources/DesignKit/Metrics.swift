import AppKit

/// The design's sizes (tokens.json of the Kelp design system): rows and bars, insets, radii, durations. Rows and bars
/// that hold chrome text are measured for normal text: read them through `TextSize.of`.
public enum Metrics {
    // Bars
    public static let panelHeader: CGFloat = 36   // an inspector panel's bar
    public static let contentBar: CGFloat = 32   // a tab's toolbar (diff, Markdown, notebook, browser)
    public static let statusBar: CGFloat = 24   // under an editor tab

    // Rows
    public static let row: CGFloat = 24   // one line in the inspector
    public static let rowTwoLine: CGFloat = 38   // a name with a line under it
    public static let rowSection: CGFloat = 26   // a section's title over its rows
    public static let rowMenu: CGFloat = 30   // Quick Open, the switcher
    public static let rowCard: CGFloat = 36   // a choice in a grouped card (the empty workspace's)

    // Spacing
    public static let inset: CGFloat = 12   // a panel's edge to its content
    public static let insetTrailing: CGFloat = 8   // a bar's edge to its last icon
    public static let indentStep: CGFloat = 12   // one outline level: the sidebar, the file tree, a group's rows
    public static let gap: CGFloat = 6   // between a bar's controls; icon to label in a row
    public static let gapWide: CGFloat = 8   // between independent controls in a tab's bar, a banner, a sheet's buttons
    public static let lineGap: CGFloat = 2   // between a row's two lines
    public static let emptyLift: CGFloat = 40   // an empty state sits this far over the middle
    public static let sheetInset: CGFloat = 20

    // Radii
    public static let radiusXS: CGFloat = 4   // chips, swatches
    public static let radiusSM: CGFloat = 6   // a row's selection, an icon button's hover
    public static let radiusMD: CGFloat = 8   // small controls floating in a tab (find bar)
    public static let radiusLG: CGFloat = 10   // the editor card, a banner, overlays inside a pane
    public static let radiusXL: CGFloat = 12   // floating panels (switcher, slide-out panel)

    // Icons
    public static let iconButton: CGFloat = 22   // an icon-only button's square
    public static let iconPoint: CGFloat = 13   // its symbol's point size
    public static let iconMenu: CGFloat = 20   // the icon of a big menu row, a section tile in Settings
    public static let appIcon: CGFloat = 16   // an app's own icon in an icon button (the browser a page opens in)
    /// Every symbol in the chrome: medium draws about the 1.3 pt line of Kelp's own glyphs (the branch, the checklist),
    /// so the system's symbols and Kelp's read as one set; regular was a hairline beside them.
    public static let iconWeight: NSFont.Weight = .medium
    // A symbol's size by where it sits; `NSImage.SymbolConfiguration.chrome` / `Font.symbol` give each the one weight.
    public static let iconTiny: CGFloat = 9   // a chevron, a tab's ✕, an arrow beside a count
    public static let iconSmall: CGFloat = 11   // beside a row's text: a tab's icon, a row's mark
    public static let iconLarge: CGFloat = 15   // a choice's icon in a grouped card, an extension's in the library
    public static let iconEmpty: CGFloat = 28   // an empty state's
    public static let iconHero: CGFloat = 40   // the one big symbol of an empty window or workspace
    public static let iconGap: CGFloat = 2   // between two icon buttons side by side
    public static let iconGlow: CGFloat = 7   // the blur of a project's colour around its icon
    public static let paneDim: CGFloat = 0.5   // how far a pane without focus fades toward the background
    public static let tabDim: CGFloat = 0.7   // what its tabs keep

    // Segments: one icon of a segmented capsule (the inspector's panels), `iconGap` apart and from the capsule's edge.
    // The symbol is as big as the title bar's toggles, which the capsule sits beside.
    public static let segment = CGSize(width: 36, height: 22)
    public static let segmentPoint: CGFloat = 14
    public static var segmentCapsule: CGFloat { segment.height + 2 * iconGap }   // the capsule's height; half of it, its radius

    // Sheets
    public static let sheetWidth: CGFloat = 480
    public static let alertAccessory: CGFloat = 400   // the fields a question sheet holds
    public static let formLabel: CGFloat = 96   // a field's name beside it, right-aligned
    public static let switcherWidth: CGFloat = 440   // the ⌃Tab switcher's card
}

extension NSImage.SymbolConfiguration {
    /// A symbol in the chrome: the one weight (`Metrics.iconWeight`) at a size from Metrics.
    public static func chrome(_ size: CGFloat = Metrics.iconPoint) -> NSImage.SymbolConfiguration {
        .init(pointSize: size, weight: Metrics.iconWeight)
    }
}

/// How long things move, and nothing under Reduce Motion.
@MainActor
public enum Motion {
    // The 80 / 120 / 180 / 240 ms scale (canvas 7.4, picked by eye against 150 / 200 / 300): things come in on it, and
    // what leaves goes in about two thirds of that, since nobody waits to watch it go.
    public static let fast: TimeInterval = 0.12   // hover, icons moving, a banner coming in
    public static let base: TimeInterval = 0.18   // a panel sliding, Quick Open opening
    public static let slow: TimeInterval = 0.17   // a banner fading: two thirds of what it took to come in
    public static let appear: TimeInterval = 0.24   // a row coming in, the attention glow
    public static let disappear: TimeInterval = 0.27   // the glow going: two thirds of the 0.4 it was
    public static let press: TimeInterval = 0.3   // a click's dip and spring
    public static let linger: TimeInterval = 1.5   // "Copied" stays, a banner stays after the pointer leaves it
    public static let stagger: TimeInterval = 0.05   // between things that come one after another
    public static let settle: TimeInterval = 0.1   // a row that just got its place, before it moves
    // A coloured project's group lighting up under the pointer, and going out: slow both ways and eased at both ends, a
    // glow that swells and fades rather than switches (at 240 / 160 ms it read as a flash).
    public static let glowIn: TimeInterval = 0.45
    public static let glowOut: TimeInterval = 0.4

    // What goes on while a state lasts, one way (a breath is this there and this back).
    public static let spin: TimeInterval = 1   // the ring's turn: working
    public static let wait: TimeInterval = 3   // the ring of dots' turn: it waits for its command
    public static let pulse: TimeInterval = 0.9   // compacting
    public static let breathe: TimeInterval = 1.2   // an agent asks
    public static let flash: TimeInterval = 1.2   // Needs You lights up and fades back

    // A hover card: the pointer rests this long on a row (a card already up follows sooner); it closes this long after.
    public static let hoverOpen: TimeInterval = 0.5
    public static let hoverOpenWarm: TimeInterval = 0.12
    public static let hoverClose: TimeInterval = 0.2

    public static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// What a press scales a view of `size` to: 4 pt off its longer side, and no more than 10 %. A share alone took 90 pt
    /// off a bar under a terminal for the 2 pt it takes off an icon.
    public static func pressDip(_ size: CGSize) -> CGFloat { 1 - min(0.1, 4 / max(size.width, size.height, 1)) }
    /// When an endless animation of this `period` starts: on the clock's beat, in the past, so every ring and glow keeps
    /// step wherever it shows, and one rebuilt carries on from where the others are.
    public static func beat(_ period: TimeInterval) -> CFTimeInterval {
        let now = CACurrentMediaTime()
        return now - fmod(now, period)
    }
    /// `seconds`, or 0 when the person asked for less motion.
    public static func duration(_ seconds: TimeInterval) -> TimeInterval { reduced ? 0 : seconds }
}

extension NSObject {
    /// Reduce Motion was switched: `selector` runs on the main thread. What moves on its own (a ring, a glow, a theme's
    /// backdrop) was built for the old setting and would go on as it was.
    @MainActor public func followReduceMotion(_ selector: Selector) {
        let name = NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: selector, name: name, object: nil)
    }
}
