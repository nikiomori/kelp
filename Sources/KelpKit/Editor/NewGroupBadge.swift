import AppKit
import DesignKit

/// The "new group" mark in the corner of an agent's icon: it fades in while the pointer is on what starts the agent
/// (`pointed`) and ⌘ alone is held, as a ⌘-click reads it (`NSEvent.isClick(with: .command)`), because a click then
/// starts it in a new group. Only what is under the pointer shows it, so only that one watches the keys.
@MainActor
final class NewGroupBadge: NSView {
    /// Whether the pointer is on the button or tile the badge is on.
    var pointed = false { didSet { if pointed != oldValue { watch() } } }
    /// Told when the badge comes or goes, for a caption that says the same.
    var onShow: ((Bool) -> Void)?
    private var shown = false
    private var keys: Any?
    /// The square in the text colour with the plus cut out of it in the window's, and a ring in the window's colour
    /// around it that parts it from the icon (as drawn: 2 pt on a 15 pt mark). Drawn here, not by an `NSImageView`,
    /// which sized this symbol shorter than it is and cut it (10.5 × 6.5 for an 11 × 11 mark).
    private let mark: NSImage
    private let ring: NSImage
    private let ringWidth: CGFloat

    init(size: CGFloat) {
        let bold = NSImage.SymbolConfiguration(pointSize: size, weight: .bold)
        mark =
            NSImage.symbol("plus.square.fill")
            .withSymbolConfiguration(bold.applying(.init(paletteColors: [.windowBackgroundColor, .labelColor])))
            ?? NSImage()
        ring =
            NSImage.symbol("square.fill")
            .withSymbolConfiguration(bold.applying(.init(paletteColors: [.windowBackgroundColor]))) ?? NSImage()
        ringWidth = size / 6
        super.init(frame: .zero)
        alphaValue = 0
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: mark.size.width + 2 * ringWidth),
            heightAnchor.constraint(equalToConstant: mark.size.height + 2 * ringWidth)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        ring.draw(in: bounds)
        mark.draw(in: bounds.insetBy(dx: ringWidth, dy: ringWidth))
    }

    /// Puts the badge in `host`, its middle on the bottom trailing corner of an icon `side` wide centred on `icon`.
    /// Called again, it pins again only if `icon` left the window and came back: a stack view takes out what it hides,
    /// and the constraints to it go too.
    func pin(to icon: NSView, side: CGFloat, in host: NSView) {
        guard icon.superview != nil, pins.isEmpty || !pins.allSatisfy(\.isActive) else { return }
        if superview !== host { host.addSubview(self) }
        pins = [
            centerXAnchor.constraint(equalTo: icon.centerXAnchor, constant: side / 2),
            centerYAnchor.constraint(equalTo: icon.centerYAnchor, constant: side / 2)
        ]
        NSLayoutConstraint.activate(pins)
    }
    private var pins: [NSLayoutConstraint] = []

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// While pointed at, follows ⌘ going down and up without the pointer moving.
    private func watch() {
        if pointed, keys == nil {
            keys = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.follow(event.modifierFlags)
                return event
            }
        } else if !pointed, let keys {
            NSEvent.removeMonitor(keys)
            self.keys = nil
        }
        follow(NSEvent.modifierFlags)
    }

    private func follow(_ flags: NSEvent.ModifierFlags) {
        let on = pointed && flags.intersection([.command, .shift, .option, .control]) == .command
        guard on != shown else { return }
        shown = on
        // It goes in two thirds of the time it took to come.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = window == nil ? 0 : Motion.duration(on ? Motion.fast : Motion.fast * 2 / 3)
            ctx.timingFunction = CAMediaTimingFunction(name: on ? .easeOut : .easeIn)
            animator().alphaValue = on ? 1 : 0
        }
        onShow?(on)
    }
}

extension NSMenu {
    /// Adds what stands in for `item`, an agent's, while ⌘ is held: "<agent> in New Group", which starts it in a new
    /// group as a ⌘-click on `item` does, with "⌘-click" at `column`. macOS swaps two items by their modifiers only
    /// when they have the same key, and a key's ⌘ doesn't count, so `item` must have no key: its own ⌘ is cleared, and
    /// an item with a key gets no stand-in (nil).
    @MainActor @discardableResult
    func addNewGroupAlternate(
        of item: NSMenuItem, agent name: String, column: CGFloat, _ action: @escaping @MainActor () -> Void
    ) -> NSMenuItem? {
        guard item.keyEquivalent.isEmpty else { return nil }
        item.keyEquivalentModifierMask = []
        let alternate = add(Self.inNewGroup(name), action)
        alternate.attributedTitle = NSMenuItem.titleWithNote(
            alternate.title, note: String(localized: "⌘-click"), column: column)
        alternate.keyEquivalentModifierMask = .command
        alternate.isAlternate = true
        alternate.show(item.image)
        return alternate
    }

    static func inNewGroup(_ agent: String) -> String { String(localized: "\(agent) in New Group") }
}
