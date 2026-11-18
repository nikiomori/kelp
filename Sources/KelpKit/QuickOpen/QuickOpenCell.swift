// A palette row's views, made once and filled again as rows scroll in (the table keeps them for reuse).
import AppKit
import Core
import DesignKit

/// The row for one item. It shows the item's icon (or an agent's state), the title, where the item is in grey, a
/// command's shortcut, what goes on the right (⌘1–⌘6, a setting's value), a built-in's view, and a tick on the choice
/// in effect.
@MainActor
final class QuickOpenCell: PaletteCell {
    static let id = NSUserInterfaceItemIdentifier("quickOpen.item")
    let image = NSImageView()
    let mark = StatusMark(size: 14)
    private let markBox = NSView()
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let key = NSTextField(labelWithString: "")
    let kind = NSTextField(labelWithString: "")
    let tick = NSImageView(image: .symbol("checkmark", String(localized: "Current")))
    private let stack = NSStackView()
    private var accessory: NSView?

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        image.contentTintColor = .secondaryLabelColor
        mark.translatesAutoresizingMaskIntoConstraints = false
        markBox.addSubview(mark)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .ui(TextSize.row)
        detail.textColor = .secondaryLabelColor
        kind.font = .ui(TextSize.caption)
        kind.textColor = .secondaryLabelColor
        tick.contentTintColor = .themeAccent
        key.font = .ui(TextSize.row)
        key.textColor = .secondaryLabelColor
        key.setContentCompressionResistancePriority(.required, for: .horizontal)
        key.setContentHuggingPriority(.required, for: .horizontal)
        // One line, as in Xcode's Open Quickly: the name, then where it is in grey, which is cut first.
        title.setContentCompressionResistancePriority(.init(260), for: .horizontal)
        title.setContentHuggingPriority(.required, for: .horizontal)
        detail.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        detail.setContentHuggingPriority(.init(1), for: .horizontal)   // takes the row's width, so the shortcut sits at its end
        for v in [image, markBox, title, detail, key, kind, tick] { stack.addArrangedSubview(v) }
        stack.detachesHiddenViews = true
        stack.spacing = Metrics.gapWide
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 12)
        for v in [kind, tick] { v.setContentHuggingPriority(.required, for: .horizontal) }
        NSLayoutConstraint.activate([
            image.widthAnchor.constraint(equalToConstant: 18), markBox.widthAnchor.constraint(equalToConstant: 18),
            mark.centerXAnchor.constraint(equalTo: markBox.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: markBox.centerYAnchor),
            markBox.heightAnchor.constraint(equalToConstant: 18)
        ])
        pin(stack)
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Shows the item's icon, or an agent's state while there's something to see (as on the agent's tab).
    func show(lead icon: NSImage?, session: Session?) {
        let state =
            session.map { [.working, .waiting, .error].contains($0.status) || ($0.status == .done && $0.unread) }
            ?? false
        markBox.isHidden = !state
        image.isHidden = state
        image.image = icon
        guard let session, state else { return }
        mark.status = session.status
        mark.unread = session.unread
        mark.follow(session)
    }

    /// Shows a built-in's view at the end, before the tick, and removes the view the reused row had.
    func show(accessory view: NSView?) {
        accessory?.removeFromSuperview()
        accessory = view
        if let view {
            stack.insertArrangedSubview(
                view, at: stack.arrangedSubviews.firstIndex(of: tick) ?? stack.arrangedSubviews.count)
        }
    }
}
