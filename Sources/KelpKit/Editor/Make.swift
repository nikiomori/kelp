import AppKit
import DesignKit

/// The pages an agent can be asked to make (Make, on the start page and in the "+" menu). Each starts the default agent
/// with a line that sends it to `kelp artifact guide`, for the user to finish with what to make.
enum Make {
    struct Kind: Sendable {
        let id: String, title: String, symbol: String, help: String
        /// The agent's line, when it isn't "Make a <id>".
        var line: String?
    }

    static let kinds = [
        Kind(
            id: "doc", title: String(localized: "Doc"), symbol: "doc.text",
            help: String(localized: "A page to read and keep")),
        Kind(
            id: "review", title: String(localized: "Review"), symbol: "checklist",
            help: String(localized: "Choices you answer on the page")),
        Kind(
            id: "slides", title: String(localized: "Slides"), symbol: "play.rectangle",
            help: String(localized: "A deck to present")),
        Kind(
            id: "design", title: String(localized: "Design"), symbol: "square.grid.2x2",
            help: String(localized: "Screens side by side")),
        Kind(
            id: "dashboard", title: String(localized: "Dashboard"), symbol: "chart.bar",
            help: String(localized: "Numbers at a glance")),
        Kind(
            id: "motion", title: String(localized: "Motion"), symbol: "film",
            help: String(localized: "A video drawn as a page")),
        Kind(
            id: "proof", title: String(localized: "Proof"), symbol: "checkmark.seal",
            help: String(localized: "Pictures that a change works")),
        Kind(
            id: "system", title: String(localized: "Design System"), symbol: "paintpalette",
            help: String(localized: "Colours, fonts and parts from a website, brand files or the project’s code"),
            line: "Make the project's design system (kelp artifact guide design system) from ")
    ]

    /// The line the agent gets; the user writes what the page is about after it. It stays in English, because it's the
    /// agent's instruction.
    static func line(_ kind: Kind) -> String { kind.line ?? "Make a \(kind.id) (kelp artifact guide \(kind.id)): " }

    /// Adds the kinds as menu items, after a "Make" heading unless they're its submenu. Each item calls `start` with
    /// its line.
    @MainActor static func addItems(to menu: NSMenu, heading: Bool = true, start: @escaping @MainActor (String) -> Void)
    {
        if heading { menu.addItem(.sectionHeader(title: String(localized: "Make"))) }
        for kind in kinds {
            let item = menu.add(kind.title) { start(line(kind)) }
            item.show(.symbol(kind.symbol))
            item.toolTip = kind.help
        }
    }
}

/// Make's choices for a built-in (the empty state of Artifacts). The default agent starts in the focused pane with the
/// line typed in, for the user to finish, as from "+".
@MainActor package func makeMenu(_ app: AppModel) -> NSMenu {
    let menu = NSMenu()
    Make.addItems(to: menu) { line in
        guard let starter = app.workbench.starter else {
            NSSound.beep()
            return
        }
        starter.newAgent(prompt: line, draft: true)
    }
    return menu
}

/// Make on the start page, in the foot of the field it fills: a small grey chip for each kind. A chip only puts a line
/// in the field, so it weighs no more than the words it adds. The chips keep their whole width and wrap onto another
/// row when the field is too narrow for them (AppKit's stack views don't wrap), so the field grows by a row.
@MainActor
final class MakeChips: NSView {
    let chips: [PointerButton]
    init(pick: @escaping (Make.Kind) -> Void) {
        chips = Make.kinds.map { kind in
            let chip = PointerButton(title: kind.title) { pick(kind) }
            chip.font = .ui(TextSize.row)
            chip.padding = Metrics.gap
            chip.restFill = .fillRest
            chip.toolTip = kind.help
            chip.setAccessibilityLabel(String(localized: "Make a \(kind.title)"))
            chip.setAccessibilityHelp(kind.help)
            return chip
        }
        super.init(frame: .zero)
        chips.forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Each chip's frame at `width`: in order, a gap apart, starting a new row (a gap below) where the next wouldn't
    /// fit.
    private func frames(_ width: CGFloat) -> [NSRect] {
        var origin = NSPoint.zero, rowHeight: CGFloat = 0
        return chips.map { chip in
            let size = chip.intrinsicContentSize
            if origin.x > 0, origin.x + size.width > width {
                origin = NSPoint(x: 0, y: origin.y + rowHeight + Metrics.gap)
                rowHeight = 0
            }
            defer {
                origin.x += size.width + Metrics.gap
                rowHeight = max(rowHeight, size.height)
            }
            return NSRect(origin: origin, size: size)
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: frames(bounds.width).map(\.maxY).max() ?? 0)
    }

    /// A new width can take another row, or one fewer.
    override func setFrameSize(_ newSize: NSSize) {
        let wider = newSize.width != frame.width
        super.setFrameSize(newSize)
        if wider { invalidateIntrinsicContentSize() }
    }

    override func layout() {
        super.layout()
        for (chip, frame) in zip(chips, frames(bounds.width)) { chip.frame = frame }
    }
}
