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
    /// How strong the badge is while shown: a pane without focus dims it with its other marks (`Metrics.tabDim`).
    var strength: CGFloat = 1
    /// The square in the text colour with the plus a hole in it, so what is under the mark shows through: no colour
    /// of its own to frame it. Drawn here, not by an `NSImageView`, which sized this symbol shorter than it is and cut
    /// it (10.5 × 6.5 for an 11 × 11 mark).
    private let mark: NSImage
    /// The room parted between the mark and the icon (as drawn: 2 pt on a 15 pt mark), cut out of the icon.
    private let gap: CGFloat
    /// The icon the gap is cut out of while the badge shows; nil where the icon is a button, whose hover fill a cut
    /// would break.
    private weak var cutIcon: NSView?

    init(size: CGFloat) {
        mark =
            NSImage.symbol("plus.square.fill")
            .withSymbolConfiguration(.init(pointSize: size, weight: .bold)) ?? NSImage()
        gap = size / 6
        super.init(frame: .zero)
        alphaValue = 0
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: mark.size.width),
            heightAnchor.constraint(equalToConstant: mark.size.height)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // The symbol is a template, drawn black: tinted in the text colour where it drew, the plus stays a hole.
        mark.draw(in: bounds)
        NSColor.labelColor.set()
        bounds.fill(using: .sourceAtop)
    }

    /// Puts the badge in `host`, its middle on the bottom trailing corner of an icon `side` wide centred on `icon`,
    /// with the gap cut out of `icon` while it shows when `cut`. Called again, it pins again only if `icon` left the
    /// window and came back: a stack view takes out what it hides, and the constraints to it go too.
    func pin(to icon: NSView, side: CGFloat, in host: NSView, cut: Bool = true) {
        guard icon.superview != nil, pins.isEmpty || !pins.allSatisfy(\.isActive) else { return }
        if superview !== host { host.addSubview(self) }
        cutIcon = cut ? icon : nil
        pins = [
            centerXAnchor.constraint(equalTo: icon.centerXAnchor, constant: side / 2),
            centerYAnchor.constraint(equalTo: icon.centerYAnchor, constant: side / 2)
        ]
        NSLayoutConstraint.activate(pins)
    }
    private var pins: [NSLayoutConstraint] = []

    /// Cuts the mark's frame, grown by the gap and rounded as the mark is, out of the icon, so the gap shows what is
    /// under the icon, as `AgentFace.cut` does.
    private func cutGap(_ on: Bool) {
        guard let icon = cutIcon else { return }
        guard on, let superview else {
            icon.layer?.mask = nil
            return
        }
        icon.wantsLayer = true
        let hole = icon.convert(frame, from: superview).insetBy(dx: -gap, dy: -gap)
        // The symbol's square is rounded about a fifth of its side; the ring around it is rounded the gap more.
        let radius = mark.size.width / 5 + gap
        let path = CGMutablePath()
        path.addRect(icon.bounds)
        path.addRoundedRect(in: hole, cornerWidth: radius, cornerHeight: radius)
        let mask = CAShapeLayer()
        mask.path = path
        mask.fillRule = .evenOdd
        icon.layer?.mask = mask
    }

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
        if on { cutGap(true) }
        // It goes in two thirds of the time it took to come, and the cut goes once it has.
        NSAnimationContext.runAnimationGroup(
            { ctx in
                ctx.duration = window == nil ? 0 : Motion.duration(on ? Motion.fast : Motion.fast * 2 / 3)
                ctx.timingFunction = CAMediaTimingFunction(name: on ? .easeOut : .easeIn)
                animator().alphaValue = on ? strength : 0
            },
            completionHandler: {
                MainActor.assumeIsolated {   // AppKit ends the group on the main thread
                    if !self.shown { self.cutGap(false) }
                }
            })
        onShow?(on)
    }
}

extension NSMenu {
    /// Adds what stands in for `item`, an agent's, while ⌘ is held: "<agent> in New Group", which starts it in a new
    /// group as a ⌘-click on `item` does. At `column` it keeps `item`'s note (its plan, in its colour), so holding ⌘
    /// hides no state; "⌘-click" only when `item` has none. macOS swaps two items by their modifiers only when they
    /// have the same key, and a key's ⌘ doesn't count, so `item` must have no key: its own ⌘ is cleared, and an item
    /// with a key gets no stand-in (nil).
    @MainActor @discardableResult
    func addNewGroupAlternate(
        of item: NSMenuItem, agent name: String, column: CGFloat, _ action: @escaping @MainActor () -> Void
    ) -> NSMenuItem? {
        guard item.keyEquivalent.isEmpty else { return nil }
        item.keyEquivalentModifierMask = []
        let alternate = add(Self.inNewGroup(name), action)
        let note = Self.note(of: item)
        alternate.attributedTitle = NSMenuItem.titleWithNote(
            alternate.title, note: note?.text ?? String(localized: "⌘-click"), column: column,
            noteColor: note?.color ?? .secondaryLabelColor)
        alternate.keyEquivalentModifierMask = .command
        alternate.isAlternate = true
        alternate.show(item.image)
        return alternate
    }

    static func inNewGroup(_ agent: String) -> String { String(localized: "\(agent) in New Group") }

    /// The note `titleWithNote` put after the tab in `item`'s title, with its colour.
    private static func note(of item: NSMenuItem) -> (text: String, color: NSColor)? {
        guard let title = item.attributedTitle else { return nil }
        let text = title.string as NSString, start = NSMaxRange(text.range(of: "\t"))
        guard start < text.length else { return nil }   // no tab: start is NSNotFound
        let color = title.attribute(.foregroundColor, at: start, effectiveRange: nil) as? NSColor
        return (text.substring(from: start), color ?? .secondaryLabelColor)
    }
}
