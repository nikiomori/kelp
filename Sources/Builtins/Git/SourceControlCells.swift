// Source Control's rows: a section's header, a changed file, a note. Each is made once and shown again for the row
// the outline hands it (`show`).
import AppKit
import Core
import DesignKit
import KelpKit

/// A row's inline actions, shown under the pointer. A reused row shows another file's actions, so the buttons run
/// what the row shows now, and are made again only when the buttons themselves differ.
@MainActor
private final class RowActions: NSStackView {
    private var actions: [RowAction] = []
    func show(_ new: [RowAction]) {
        defer { actions = new }
        guard new.map(\.symbol) != actions.map(\.symbol) || new.map(\.title) != actions.map(\.title) else { return }
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        for index in new.indices {
            // The button greys in under the pointer and dips when pressed.
            let button = IconButton(.symbol(new[index].symbol), tip: new[index].title) { [weak self] in
                self?.actions[index].run()
            }
            button.symbolConfiguration = .chrome(Metrics.iconSmall)
            addArrangedSubview(button)
        }
    }
    init() {
        super.init(frame: .zero)
        spacing = Metrics.iconGap
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor @discardableResult
private func pinRow(_ cell: NSView, _ views: [NSView], leading: CGFloat) -> NSLayoutConstraint {
    let row = NSStackView(views: views)
    row.spacing = Metrics.gap
    row.alignment = .centerY
    row.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(row)
    let lead = row.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading)
    NSLayoutConstraint.activate([
        lead, row.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Metrics.inset),
        row.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
    ])
    return lead
}

/// A section's header row. Its views are made once, and `show` sets everything it shows, because the outline hands a
/// row it set aside to another section.
final class SectionCell: NSTableCellView, Hoverable {
    static let id = NSUserInterfaceItemIdentifier("scm.section")
    /// Where the section's rows start past the inset: under its title, after the chevron.
    static let indent: CGFloat = 16
    private let chevron = NSImageView()
    private let actions = RowActions()
    private let titleField = NSTextField.label(
        "", font: .ui(TextSize.caption, weight: .semibold), color: .secondaryLabelColor)
    private let capsule = CountCapsule()
    private let detailField = NSTextField(labelWithString: "")
    private var open = true
    /// Whether the section is open. Setting it turns the chevron from what it showed.
    var expanded: Bool {
        get { open }
        set {
            let was = open
            open = newValue
            showChevron()
            if newValue != was { chevron.turn(from: Self.turn(newValue)) }
        }
    }
    /// The angle the chevron turns from: what it showed. `Self.turn(expanded)` gives it for a cell just rebuilt.
    static func turn(_ expanded: Bool) -> CGFloat { expanded ? .pi / 2 : -.pi / 2 }
    /// True when a click folded or opened the section, so the new cell's chevron turns once the cell has a size.
    var turnsIn = false
    override func layout() {
        super.layout()
        if turnsIn {
            turnsIn = false
            chevron.turn(from: Self.turn(expanded))
        }
    }
    private func showChevron() { chevron.image = .symbol(open ? "chevron.down" : "chevron.right") }
    init() {
        super.init(frame: .zero)
        identifier = Self.id
        chevron.symbolConfiguration = .chrome(Metrics.iconTiny)
        chevron.contentTintColor = .secondaryLabelColor
        chevron.widthAnchor.constraint(equalToConstant: 10).isActive = true
        // In a narrow panel the line counts give way before the section's name.
        detailField.lineBreakMode = .byTruncatingTail
        detailField.setContentCompressionResistancePriority(.init(240), for: .horizontal)
        // The row starts at the panel's edge, as the header's branch does.
        pinRow(self, [chevron, titleField, NSView(), actions, detailField, capsule], leading: Metrics.inset)
        showChevron()
    }
    convenience init(title: String, count: Int?, expanded: Bool, actions rowActions: [RowAction]) {
        self.init()
        show(title: title, count: count, expanded: expanded, actions: rowActions)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Sets again everything a section's row shows, so nothing of the section it showed before stays.
    func show(
        title: String, count: Int?, expanded: Bool, actions rowActions: [RowAction], detail: NSAttributedString? = nil
    ) {
        titleField.stringValue = title
        capsule.text = count.map(String.init) ?? ""
        capsule.isHidden = count == nil
        detailField.attributedStringValue = detail ?? NSAttributedString()
        detailField.isHidden = detail == nil
        actions.show(rowActions)
        busy = false
        hovering = false
        actions.isHidden = true
        open = expanded
        turnsIn = false
        toolTip = nil
        showChevron()
    }
    func setHover(_ on: Bool) {
        hovering = on
        guard !busy else { return }
        actions.superview?.crossfade()
        actions.isHidden = !on
    }
    private var hovering = false
    /// True while the section's first action is at work (the graph's Refresh). A spinner takes its place, and stays
    /// when the pointer goes.
    var busy = false {
        didSet {
            guard busy != oldValue else { return }
            (actions.arrangedSubviews.first as? IconButton)?.busy = busy
            if !busy, !hovering { setHover(false) } else { actions.isHidden = false }
        }
    }
}

/// A changed file's row, in the changes or under a commit of the graph. Its views are made once, and `show` sets
/// everything it shows, because the outline hands a row it set aside to another file.
final class FileCell: NSTableCellView, Hoverable {
    static let id = NSUserInterfaceItemIdentifier("scm.file")
    private let actions = RowActions()
    private(set) var path = ""
    private let icon = NSImageView(), mark = NSImageView()
    private let name = NSTextField(labelWithString: ""), dir = NSTextField(labelWithString: "")
    private let letterField = NSTextField(labelWithString: ""), number = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint?
    /// Under a commit, the lanes below it, which run on through its files as in VS Code.
    private var lanes: GraphView?

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        name.font = .ui(TextSize.row)
        name.lineBreakMode = .byTruncatingMiddle   // as Finder cuts a name, so its extension stays
        dir.font = .ui(TextSize.caption)
        dir.textColor = .secondaryLabelColor
        dir.lineBreakMode = .byTruncatingHead
        dir.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        name.setContentCompressionResistancePriority(.init(400), for: .horizontal)
        letterField.font = .ui(TextSize.micro, weight: .bold)   // a git letter as Files and the diff's list draw it
        letterField.alignment = .center
        letterField.widthAnchor.constraint(equalToConstant: 12).isActive = true
        mark.symbolConfiguration = .chrome(Metrics.iconTiny)
        mark.contentTintColor = .secondaryLabelColor   // grey, so it isn't read as the orange M beside it
        number.font = .uiDigits(TextSize.micro, weight: .semibold)
        number.textColor = .secondaryLabelColor
        leading = pinRow(self, [icon, name, dir, NSView(), actions, mark, number, letterField], leading: Metrics.inset)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `shared` holds the branches of other folders of the project that change this file too
    /// (`AppModel.sharedFiles`). `through` holds, under a commit, the lanes that run on past it and the graph's width.
    func show(
        _ fileChange: FileChange, icon image: NSImage, letter: (String, NSColor), indent: CGFloat,
        actions rowActions: [RowAction],
        shared: [String] = [], commit: Int? = nil, through: (lanes: [Int], width: CGFloat)? = nil
    ) {
        alphaValue = 1   // a discarded file's row was faded out (`fadeRows`)
        path = fileChange.path
        actions.show(rowActions)
        actions.isHidden = true
        icon.image = image
        let fileName = (fileChange.path as NSString).lastPathComponent
        if letter.0 == "D" {
            name.attributedStringValue = NSAttributedString(
                string: fileName, attributes: [.strikethroughStyle: 1, .font: NSFont.ui(TextSize.row)])
        } else {
            name.stringValue = fileName
        }
        dir.stringValue = (fileChange.path as NSString).deletingLastPathComponent
        letterField.stringValue = letter.0
        letterField.textColor = letter.1
        letterField.setAccessibilityLabel(gitLetterWord(letter.0))   // VoiceOver reads a bare "M" as a letter
        let tip = shared.isEmpty ? nil : String(localized: "Also changed on \(shared.joined(separator: ", "))")
        // The merge mark goes before the letter, where the eye checks a file's state.
        mark.image = tip.map { .symbol("arrow.triangle.merge", $0) }
        mark.isHidden = tip == nil
        // The number of the plan's commit the file goes into, the same number as on its card over the button.
        number.stringValue = commit.map(String.init) ?? ""
        number.isHidden = commit == nil
        number.toolTip = commit.map { String(localized: "In commit \($0) of the plan") }
        leading?.constant = indent + Metrics.inset
        toolTip = [fileChange.path, tip].compactMap { $0 }.joined(separator: "\n")
        showLanes(through)
    }

    private func showLanes(_ through: (lanes: [Int], width: CGFloat)?) {
        guard let through else {
            lanes?.isHidden = true
            return
        }
        let graph = lanes ?? GraphView()
        if lanes == nil {
            graph.autoresizingMask = [.height]
            addSubview(graph)
            lanes = graph
        }
        graph.isHidden = false
        graph.through = through.lanes
        graph.frame = NSRect(x: GraphView.leading, y: 0, width: through.width, height: max(bounds.height, 22))
        graph.needsDisplay = true
    }
    func setHover(_ on: Bool) {
        actions.superview?.crossfade()
        actions.isHidden = !on
    }
}

final class NoteCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("scm.note")
    private let field = NSTextField.label("", font: .ui(TextSize.row), color: .secondaryLabelColor)
    init() {
        super.init(frame: .zero)
        identifier = Self.id
        pinRow(self, [field], leading: Metrics.inset + SectionCell.indent)
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(_ text: String) { field.stringValue = text }
}
