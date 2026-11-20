import AppKit
import DesignKit

/// The "new group" mark in the corner of an agent's icon: it fades in while the pointer is on what starts the agent
/// (`pointed`) and ⌘ alone is held, as a ⌘-click reads it (`NSEvent.isClick(with: .command)`), because a click then
/// starts it in a new group. Only what is under the pointer shows it, so only that one watches the keys.
@MainActor
final class NewGroupBadge: NSImageView {
    /// Whether the pointer is on the button or tile the badge is on.
    var pointed = false { didSet { if pointed != oldValue { watch() } } }
    /// Told when the badge comes or goes, for a caption that says the same.
    var onShow: ((Bool) -> Void)?
    private var shown = false
    private var keys: Any?

    init(size: CGFloat) {
        super.init(frame: .zero)
        image = .symbol("plus.square.fill")
        // The square in the text colour and the plus cut out of it in the window's, as a mark on an icon.
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .bold)
            .applying(.init(paletteColors: [.windowBackgroundColor, .labelColor]))
        alphaValue = 0
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Puts the badge in `host`, its middle on the bottom trailing corner of an icon `side` wide centred on `icon`.
    func pin(to icon: NSView, side: CGFloat, in host: NSView) {
        host.addSubview(self)
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: icon.centerXAnchor, constant: side / 2),
            centerYAnchor.constraint(equalTo: icon.centerYAnchor, constant: side / 2)
        ])
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
