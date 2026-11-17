import AppKit
import Core
import DesignKit
import KelpKit

struct RowAction {
    let symbol: String, title: String, run: @MainActor () -> Void
    /// `title` is in English; it shows translated (in the tooltip, accessibility and the context menu).
    init(_ symbol: String, _ title: String, _ run: @escaping @MainActor () -> Void) {
        self.symbol = symbol
        self.title = loc(title)
        self.run = run
    }
}

/// The Graph pane's header. A click folds the pane and a drag sizes it (VS Code's view header and sash in one).
final class GraphBar: NSView {
    static let height = TextSize.of(26) + 1
    var onToggle: (() -> Void)?, onResize: ((CGFloat) -> Void)?, onRefresh: (() -> Void)?
    var expanded = true {
        didSet {
            cell?.expanded = expanded
            window?.invalidateCursorRects(for: self)
        }
    }
    private var cell: SectionCell?
    /// Whether Refresh is at work.
    var busy: Bool {
        get { cell?.busy ?? false }
        set { cell?.busy = newValue }
    }
    /// Under the pointer the header greys in as a list row does (inset, rounded), and while it's held it darkens.
    private let fill = NSView()
    private var hovering = false, pressed = false

    init() {
        super.init(frame: .zero)
        let sectionCell = SectionCell(
            title: loc(SourceControlController.Section.graph.rawValue), count: nil, expanded: true,
            actions: [RowAction("arrow.clockwise", "Refresh") { [weak self] in self?.onRefresh?() }])
        let sep = NSBox()
        sep.boxType = .separator
        fill.wantsLayer = true
        fill.layer?.cornerRadius = Metrics.radiusSM
        for v in [sep, fill, sectionCell] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            fill.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 1),
            fill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            fill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            fill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            sep.topAnchor.constraint(equalTo: topAnchor), sep.heightAnchor.constraint(equalToConstant: 1),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            sectionCell.topAnchor.constraint(equalTo: sep.bottomAnchor),
            sectionCell.bottomAnchor.constraint(equalTo: bottomAnchor),
            sectionCell.leadingAnchor.constraint(equalTo: leadingAnchor),
            sectionCell.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        cell = sectionCell
        clipsToBounds = true
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel(loc("Graph"))
    }
    required init?(coder: NSCoder) { fatalError() }

    private func showFill() {
        fill.fadeBackground(to: pressed ? .fillSelected : hovering ? .fillHover : nil, held: pressed)
    }
    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }
    private func setHovering(_ on: Bool) {
        cell?.setHover(on)
        hovering = on
        showFill()
    }
    override func resetCursorRects() {
        if expanded {
            addCursorRect(NSRect(x: 0, y: bounds.height - 4, width: bounds.width, height: 4), cursor: .resizeUpDown)
        }
    }
    override func accessibilityPerformPress() -> Bool {
        onToggle?()
        return true
    }
    override func accessibilityValue() -> Any? { expanded }

    private var start: CGFloat = 0, last: CGFloat = 0, dragged = false
    override func mouseDown(with event: NSEvent) {
        start = event.locationInWindow.y
        last = start
        dragged = false
        pressed = true
        showFill()
    }
    override func mouseDragged(with event: NSEvent) {
        let pointerY = event.locationInWindow.y
        dragged = dragged || (expanded && abs(pointerY - start) > 3)
        guard dragged else { return }
        if pressed {
            pressed = false
            showFill()
        }
        onResize?(pointerY - last)
        last = pointerY
    }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        showFill()
        guard !dragged else { return }
        wantsLayer = true
        pressBounce()
        onToggle?()
    }
}

/// The commit message, where ⌘↩ commits, as in VS Code.
final class CommitTextView: NSTextView {
    var onCommit: (() -> Void)?
    /// Called for ⌥⌘↩, which has the agent write the message.
    var onAgent: (() -> Void)?
    /// Room kept free in the top-right corner, where the agent's logo sits over the field. The first line wraps before
    /// it, and the lines under it run the whole width.
    var corner: CGFloat = 0 { didSet { if corner != oldValue { exclude() } } }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        exclude()
    }
    private func exclude() {
        guard let container = textContainer else { return }
        let rect = NSRect(x: container.size.width - corner, y: 0, width: corner, height: 14)   // the first line
        container.exclusionPaths = corner > 0 ? [NSBezierPath(rect: rect)] : []
    }
    var onChange: (() -> Void)?
    private func isCommitKey(_ event: NSEvent) -> Bool {
        (event.keyCode == 36 || event.keyCode == 76) && event.modifierFlags.contains(.command)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, isCommitKey(event) {
            if event.modifierFlags.contains(.option), let onAgent { onAgent() } else { onCommit?() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        guard isCommitKey(event) else { return super.keyDown(with: event) }
        if event.modifierFlags.contains(.option), let onAgent { onAgent() } else { onCommit?() }
    }
    override func didChangeText() {
        super.didChangeText()
        onChange?()
    }
}

/// The message field's rounded border. AppKit calls `updateLayer` again on every light / dark change.
class FieldBox: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = Metrics.radiusSM
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }
}
