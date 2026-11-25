import AppKit

/// The design's sizes (tokens.json of the Kelp design system): rows and bars, insets, radii, durations. Rows and bars
/// that hold chrome text are measured for normal text, so read them through `TextSize.of`.
public enum Metrics {
    // Bars
    public static let panelHeader: CGFloat = 36   // an inspector panel's bar
    public static let contentBar: CGFloat = 32   // a tab's toolbar (diff, Markdown, notebook, browser)
    public static let statusBar: CGFloat = 24   // under an editor tab
    /// The system title bar's height (28 pt before macOS 26, 32 after), which the window's own bar takes.
    @MainActor public static let titleBar = NSWindow.frameRect(forContentRect: .zero, styleMask: [.titled]).height

    // Rows
    public static let row: CGFloat = 24   // one line in the inspector
    public static let rowTwoLine: CGFloat = 40   // a name with a line under it
    public static let rowSection: CGFloat = 28   // a section's title over its rows
    public static let rowMenu: CGFloat = 32   // Quick Open, the switcher
    public static let rowCard: CGFloat = 36   // a choice in a grouped card (the empty workspace's)
    public static let countCapsule: CGFloat = 16   // a section's count on its capsule

    // Spacing
    public static let inset: CGFloat = 12   // a panel's edge to its content
    public static let insetTrailing: CGFloat = 8   // a bar's edge to its last icon
    public static let indentStep: CGFloat = 12   // one outline level: the file tree, a group's rows (sidebar: 12)
    public static let gap: CGFloat = 6   // between a bar's controls; icon to label in a row
    public static let gapWide: CGFloat = 8   // between separate controls in a tab's bar, a banner, or a sheet's buttons
    public static let lineGap: CGFloat = 2   // between a row's two lines
    public static let gapTight: CGFloat = 4   // a count's digits to its capsule's edge
    public static let emptyLift: CGFloat = 40   // an empty state sits this far over the middle
    public static let sheetInset: CGFloat = 20
    // A page (a tab of data: a server, Usage, a machine): its content's sides, its top and bottom, and the space
    // between its blocks. A title stands `gapWide` over what it names. A table across the page and split panes have
    // no margins.
    public static let pageInset: CGFloat = 20
    public static let pageTop: CGFloat = 16
    public static let blockGap: CGFloat = 20
    public static let pageColumn: CGFloat = 560   // the widest a page's column of text and facts runs

    // Radii
    public static let radiusXS: CGFloat = 4   // chips, swatches
    public static let radiusSM: CGFloat = 6   // a row's selection and an icon button's hover
    public static let radiusMD: CGFloat = 8   // small controls floating in a tab (find bar)
    public static let radiusLG: CGFloat = 10   // the editor card, a banner, overlays inside a pane
    public static let radiusXL: CGFloat = 12   // floating panels (switcher, slide-out panel)

    // Icons
    public static let iconButton: CGFloat = 22   // an icon-only button's square
    public static let iconPoint: CGFloat = 13   // its symbol's point size
    public static let iconMenu: CGFloat = 20   // the icon of a big menu row, a section tile in Settings
    public static let appIcon: CGFloat = 16   // an app's own icon in an icon button (the browser a page opens in)
    /// The weight of every symbol in the chrome. Medium draws about the 1.3 pt line of Kelp's own glyphs (the branch,
    /// the checklist), so the system's symbols and Kelp's read as one set; regular was a hairline beside them.
    public static let iconWeight: NSFont.Weight = .medium
    // A symbol's size by where it sits. `NSImage.SymbolConfiguration.chrome` and `Font.symbol` give each one the one
    // weight.
    public static let iconTiny: CGFloat = 9   // a chevron, a tab's ✕, an arrow beside a count
    public static let iconSmall: CGFloat = 11   // beside a row's text: a tab's icon, a row's mark
    public static let iconLarge: CGFloat = 15   // a choice's icon in a grouped card; an extension's in the library
    public static let iconEmpty: CGFloat = 28   // an empty state's icon
    public static let iconHero: CGFloat = 40   // the one big symbol of an empty window or workspace
    public static let iconGap: CGFloat = 2   // between two icon buttons side by side
    public static let iconGlow: CGFloat = 7   // the blur of a project's colour around its icon
    public static let paneDim: CGFloat = 0.5   // how far a pane without focus fades toward the background
    public static let unlit: CGFloat = 0.25   // what is off the pointer's path in a drawn map
    public static let stroke: CGFloat = 1.4   // a drawn ring or curve: a map's nodes, a list's lanes
    public static let hairline: CGFloat = 1   // the thinnest drawn line: hatching
    public static let strokeBold: CGFloat = 2   // a drawn line that stands out: a lit path, a selection ring
    public static let markRadius: CGFloat = 2   // the corners of a small drawn square: an edited file's mark
    public static let dotRadius: CGFloat = 3   // a small drawn dot: where the agent is now
    public static let cardWidth: CGFloat = 300   // the widest a card under the pointer grows
    public static let zoom: ClosedRange<CGFloat> = 0.3...2   // how far a drawn map zooms out and in
    public static let zoomReadable: CGFloat = 0.6   // the smallest a fitted map shrinks to, its words still read
    public static let zoomStep: CGFloat = 1.25   // one press of Zoom In (Zoom Out divides by it)
    public static let dash: [CGFloat] = [2, 1.5]   // a dashed ring: a place outside, a question
    public static let tabDim: CGFloat = 0.7   // the opacity a dimmed tab strip's tabs keep

    // Segments: one icon of a segmented capsule (the inspector's panels), `iconGap` apart from each other and from the
    // capsule's edge. The symbol is as big as the title bar's toggles, which the capsule sits beside.
    public static let segment = CGSize(width: 36, height: 22)
    public static let segmentPoint: CGFloat = 14
    // The capsule's height; half of it is its radius.
    public static var segmentCapsule: CGFloat { segment.height + 2 * iconGap }

    // Sheets
    public static let sheetWidth: CGFloat = 480
    public static let popoverWidth: CGFloat = 300   // a popover's text column (commit and sync take 320)
    public static let codeCardWidth: CGFloat = 440   // a popover of code (docs, a change): lines read better wide
    public static let alertAccessory: CGFloat = 400   // the width of the fields a question sheet holds
    public static let formLabel: CGFloat = 96   // a field's name beside it, right-aligned
    public static let switcherWidth: CGFloat = 440   // the ⌃Tab switcher's card
}

extension NSImage.SymbolConfiguration {
    /// The configuration of a symbol in the chrome: the one weight (`Metrics.iconWeight`) at a size from Metrics.
    public static func chrome(_ size: CGFloat = Metrics.iconPoint) -> NSImage.SymbolConfiguration {
        .init(pointSize: size, weight: Metrics.iconWeight)
    }
}

/// How long things move, and nothing under Reduce Motion.
@MainActor
public enum Motion {
    // The 120 / 180 / 240 / 320 ms scale (canvas 7.4, picked by eye against 150 / 200 / 300; 320 is `fold`). Things
    // come in on it, and what leaves goes in about two thirds of that, because nobody waits to watch it go.
    public nonisolated static let fast: TimeInterval = 0.12   // hover, icons moving, the picture of what went fading
    public nonisolated static let base: TimeInterval = 0.18   // a panel sliding, Quick Open opening
    public nonisolated static let slow: TimeInterval = 0.17   // a banner fading: two thirds of what it took to come in
    public nonisolated static let appear: TimeInterval = 0.24   // a row or a banner coming in, the attention glow
    public static let disappear: TimeInterval = 0.27   // the glow going, two thirds of the 0.4 it was
    public static let press: TimeInterval = 0.3   // a click's dip and spring
    public static let linger: TimeInterval = 1.5   // how long "Copied" stays, or a banner after the pointer leaves it
    public static let stagger: TimeInterval = 0.05   // between things that come one after another
    public static let settle: TimeInterval = 0.1   // a row that just got its place, before it moves
    // A coloured project's group lighting up under the pointer, and going out. It is slow both ways and eased at both
    // ends, a glow that swells and fades rather than switches (at 240 / 160 ms it read as a flash).
    public static let glowIn: TimeInterval = 0.45
    public static let glowOut: TimeInterval = 0.4
    // A project or workspace folding, with the chevron turning and rows coming and going. It is long enough to follow,
    // and on `soft` so it still answers the click at once (at 180 ms on easeOut it read as a snap).
    public static let fold: TimeInterval = 0.32
    /// Starts moving at once and settles slowly, so it reads as a fold, not a switch. easeInEaseOut read as lag on a
    /// click.
    public static var soft: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.25, 0.8, 0.25, 1) }

    // A hidden panel at the window's edge, as Arc's sidebar does it (measured from a 120 fps recording): the pointer
    // rests at the edge this long before the panel comes, so brushing past it brings nothing. Arc's 0.3 read as lag.
    public static let edgeRest: TimeInterval = 0.1
    /// The panel coming in: in place in about 85 ms, some 5 % past it (13 pt for a sidebar) at 110 ms, and back by
    /// 200 ms. Its damping is 0.7 of critical, so it goes past once and doesn't wobble. Arc's 1 % (0.8) read as no
    /// spring.
    public static func slideIn(_ keyPath: String) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.stiffness = 1500
        spring.damping = 54
        spring.duration = spring.settlingDuration
        return spring
    }

    // What goes on while a state lasts, one way (a breath takes this long there and this long back).
    public static let spin: TimeInterval = 1   // the ring's turn while the agent works
    public static let wait: TimeInterval = 3   // the turn of the ring of dots while it waits for its command
    public static let pulse: TimeInterval = 0.9   // while compacting
    public static let breathe: TimeInterval = 1.2   // while an agent asks
    public static let flash: TimeInterval = 1.2   // Needs You lights up and fades back

    // A hover card opens once the pointer rests this long on a row (a card already up follows sooner), and closes this
    // long after the pointer leaves.
    public static let hoverOpen: TimeInterval = 0.5
    public static let hoverOpenWarm: TimeInterval = 0.12
    public static let hoverClose: TimeInterval = 0.2
    // How long after a card went the next still opens at `hoverOpenWarm`, so the pointer moving on to the next row
    // isn't made to wait again.
    public static let hoverWarm: TimeInterval = 0.8

    /// Whether to reduce motion, as the Mac says unless `pinned`.
    public static var reduced: Bool { pinned ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Set by tests, so what moves is checked whatever the Mac running them asks for (CI's runners ask for less
    /// motion).
    public static var pinned: Bool?
    /// The scale a press shrinks a view of `size` to: 4 pt off its longer side, and no more than 10 %. A share alone
    /// took 90 pt off a bar under a terminal for the 2 pt it takes off an icon.
    public static func pressDip(_ size: CGSize) -> CGFloat { 1 - min(0.1, 4 / max(size.width, size.height, 1)) }
    /// When an endless animation of this `period` starts: on the clock's beat, in the past, so every ring and glow
    /// keeps step wherever it shows, and one rebuilt carries on from where the others are.
    public static func beat(_ period: TimeInterval) -> CFTimeInterval {
        let now = CACurrentMediaTime()
        return now - fmod(now, period)
    }
    /// `seconds`, or 0 when the person asked for less motion.
    public static func duration(_ seconds: TimeInterval) -> TimeInterval { reduced ? 0 : seconds }
}

extension NSObject {
    /// Runs `selector` on the main thread when Reduce Motion was switched, because what moves on its own (a ring, a
    /// glow, a theme's backdrop) was built for the old setting and would go on as it was.
    @MainActor public func followReduceMotion(_ selector: Selector) {
        let name = NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: selector, name: name, object: nil)
    }
}
