import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

struct RowAction {
    let symbol: String, title: String, run: @MainActor () -> Void
    /// `title` in English; it shows translated (tooltip, accessibility, context menu).
    init(_ symbol: String, _ title: String, _ run: @escaping @MainActor () -> Void) {
        self.symbol = symbol
        self.title = loc(title)
        self.run = run
    }
}

@MainActor
private func actionButtons(_ actions: [RowAction]) -> NSStackView {
    let stack = NSStackView(
        views: actions.map { action in
            let button = IconButton(.symbol(action.symbol), tip: action.title) { action.run() }   // greys in under the pointer, dips when pressed
            button.symbolConfiguration = .chrome(Metrics.iconSmall)
            return button
        })
    stack.spacing = Metrics.iconGap
    stack.isHidden = true
    return stack
}

@MainActor
private func pinRow(_ cell: NSView, _ views: [NSView], leading: CGFloat, trailing: CGFloat = 10) {
    let row = NSStackView(views: views)
    row.spacing = Metrics.gap
    row.alignment = .centerY
    row.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(row)
    NSLayoutConstraint.activate([
        row.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading),
        row.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -trailing),
        row.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
    ])
}

final class SectionCell: NSTableCellView, Hoverable {
    /// Where its rows start, past the inset: under its title, after the chevron.
    static let indent: CGFloat = 16
    private let chevron = NSImageView()
    private let actions: NSStackView
    var expanded = true {
        didSet {
            showChevron()
            if expanded != oldValue { chevron.turn(from: Self.turn(expanded)) }
        }
    }
    /// Where the chevron starts when it turns: from what it showed. `Self.turn(expanded)` for one just rebuilt.
    static func turn(_ expanded: Bool) -> CGFloat { expanded ? .pi / 2 : -.pi / 2 }
    /// The section was folded or opened by a click: its new cell's chevron turns there once it has a size.
    var turnsIn = false
    override func layout() {
        super.layout()
        if turnsIn {
            turnsIn = false
            chevron.turn(from: Self.turn(expanded))
        }
    }
    private func showChevron() { chevron.image = .symbol(expanded ? "chevron.down" : "chevron.right") }
    init(title: String, count: Int?, expanded: Bool, actions a: [RowAction], detail: NSAttributedString? = nil) {
        actions = actionButtons(a)
        super.init(frame: .zero)
        chevron.symbolConfiguration = .chrome(Metrics.iconTiny)
        chevron.contentTintColor = .secondaryLabelColor
        chevron.widthAnchor.constraint(equalToConstant: 10).isActive = true
        let titleField = NSTextField.label(
            title, font: .ui(TextSize.caption, weight: .semibold), color: .secondaryLabelColor)
        let capsule = CountCapsule(count.map(String.init) ?? "")
        capsule.isHidden = count == nil
        let detailField = NSTextField(labelWithAttributedString: detail ?? NSAttributedString())
        detailField.isHidden = detail == nil
        pinRow(self, [chevron, titleField, NSView(), actions, detailField, capsule], leading: Metrics.inset)   // the panel's edge, as its header's branch
        self.expanded = expanded
        showChevron()   // didSet doesn't run in init
    }
    required init?(coder: NSCoder) { fatalError() }
    func setHover(_ on: Bool) {
        actions.superview?.crossfade()
        actions.isHidden = !on
    }
}

/// A section's file count on a grey capsule, as VS Code's: beside "+6 −2" a bare "3" ran into it.
private final class CountCapsule: NSView {
    init(_ text: String) {
        super.init(frame: .zero)
        let field = NSTextField(labelWithString: text)
        field.font = .uiDigits(TextSize.micro, weight: .semibold)
        field.textColor = .secondaryLabelColor
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            field.centerYAnchor.constraint(equalTo: centerYAnchor), heightAnchor.constraint(equalToConstant: 16),
            widthAnchor.constraint(greaterThanOrEqualTo: heightAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.fillSelected.cgColor
        layer?.cornerRadius = bounds.height / 2
    }
    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
}

/// The Graph pane's header: a click folds the pane, a drag sizes it (VS Code's view header and sash in one).
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
    /// Under the pointer the header greys in as a list row does (inset, rounded), held it darkens.
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
    override func mouseEntered(with e: NSEvent) { setHovering(true) }
    override func mouseExited(with e: NSEvent) { setHovering(false) }
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
    override func mouseDown(with e: NSEvent) {
        start = e.locationInWindow.y
        last = start
        dragged = false
        pressed = true
        showFill()
    }
    override func mouseDragged(with e: NSEvent) {
        let pointerY = e.locationInWindow.y
        dragged = dragged || (expanded && abs(pointerY - start) > 3)
        guard dragged else { return }
        if pressed {
            pressed = false
            showFill()
        }
        onResize?(pointerY - last)
        last = pointerY
    }
    override func mouseUp(with e: NSEvent) {
        pressed = false
        showFill()
        guard !dragged else { return }
        wantsLayer = true
        pressBounce()
        onToggle?()
    }
}

final class FileCell: NSTableCellView, Hoverable {
    private let actions: NSStackView
    let path: String
    /// `shared`: the branches of other folders of the project that change this file too (`AppModel.sharedFiles`).
    init(
        _ f: FileChange, icon image: NSImage, letter: (String, NSColor), indent: CGFloat, actions a: [RowAction],
        shared: [String] = [], commit: Int? = nil
    ) {
        actions = actionButtons(a)
        path = f.path
        super.init(frame: .zero)
        let icon = NSImageView(image: image)
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let name = NSTextField(labelWithString: (f.path as NSString).lastPathComponent)
        name.font = .ui(TextSize.row)
        name.lineBreakMode = .byTruncatingTail
        if letter.0 == "D" {
            name.attributedStringValue = NSAttributedString(
                string: name.stringValue, attributes: [.strikethroughStyle: 1, .font: NSFont.ui(TextSize.row)])
        }
        let dir = NSTextField(labelWithString: (f.path as NSString).deletingLastPathComponent)
        dir.font = .ui(TextSize.caption)
        dir.textColor = .secondaryLabelColor
        dir.lineBreakMode = .byTruncatingHead
        dir.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        name.setContentCompressionResistancePriority(.init(400), for: .horizontal)
        let letterField = NSTextField(labelWithString: letter.0)
        letterField.font = .uiMono(TextSize.caption, weight: .semibold)
        letterField.textColor = letter.1
        letterField.alignment = .center
        letterField.widthAnchor.constraint(equalToConstant: 12).isActive = true
        let tip = shared.isEmpty ? nil : String(localized: "Also changed on \(shared.joined(separator: ", "))")
        let mark = NSImageView()
        if let tip {   // before the letter, where the eye checks a file's state
            mark.image = .symbol("arrow.triangle.merge", tip)
            mark.symbolConfiguration = .chrome(Metrics.iconTiny)
            mark.contentTintColor = .textOrange
        }
        mark.isHidden = tip == nil
        // The plan's commit it goes into: the same number as its card over the button.
        let number = NSTextField(labelWithString: commit.map(String.init) ?? "")
        number.font = .uiDigits(TextSize.micro, weight: .semibold)
        number.textColor = .secondaryLabelColor
        number.isHidden = commit == nil
        number.toolTip = commit.map { String(localized: "In commit \($0) of the plan") }
        pinRow(self, [icon, name, dir, NSView(), actions, mark, number, letterField], leading: indent + Metrics.inset)
        toolTip = [f.path, tip].compactMap { $0 }.joined(separator: "\n")
    }
    required init?(coder: NSCoder) { fatalError() }
    func setHover(_ on: Bool) {
        actions.superview?.crossfade()
        actions.isHidden = !on
    }
}

final class NoteCell: NSTableCellView {
    init(_ text: String) {
        super.init(frame: .zero)
        let field = NSTextField.label(text, font: .ui(TextSize.row), color: .secondaryLabelColor)
        pinRow(self, [field], leading: Metrics.inset + SectionCell.indent)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// The commit message: ⌘↩ commits, like VS Code.
final class CommitTextView: NSTextView {
    var onCommit: (() -> Void)?
    /// ⌥⌘↩: the agent writes it.
    var onAgent: (() -> Void)?
    var onChange: (() -> Void)?
    private func isCommitKey(_ e: NSEvent) -> Bool {
        (e.keyCode == 36 || e.keyCode == 76) && e.modifierFlags.contains(.command)
    }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if window?.firstResponder === self, isCommitKey(e) {
            if e.modifierFlags.contains(.option), let onAgent { onAgent() } else { onCommit?() }
            return true
        }
        return super.performKeyEquivalent(with: e)
    }
    override func keyDown(with e: NSEvent) {
        guard isCommitKey(e) else { return super.keyDown(with: e) }
        if e.modifierFlags.contains(.option), let onAgent { onAgent() } else { onCommit?() }
    }
    override func didChangeText() {
        super.didChangeText()
        onChange?()
    }
}

/// The message field's rounded border; AppKit calls `updateLayer` again on every light / dark change.
class FieldBox: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = Metrics.radiusSM
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }
}
