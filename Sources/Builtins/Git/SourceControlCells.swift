// Source Control's rows: a section's header, a changed file, a note. Each is made once and shown again for the row
// the outline hands it (`show`).
import AppKit
import Core
import DesignKit
import KelpKit

/// A row's inline actions, shown under the pointer. A reused row shows another file's: the buttons run what it shows
/// now, and are made again only when they're other buttons.
@MainActor
private final class RowActions: NSStackView {
    private var actions: [RowAction] = []
    func show(_ new: [RowAction]) {
        defer { actions = new }
        guard new.map(\.symbol) != actions.map(\.symbol) || new.map(\.title) != actions.map(\.title) else { return }
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        for index in new.indices {
            // greys in under the pointer, dips when pressed
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
private func pinRow(_ cell: NSView, _ views: [NSView], leading: CGFloat, trailing: CGFloat = 10) -> NSLayoutConstraint {
    let row = NSStackView(views: views)
    row.spacing = Metrics.gap
    row.alignment = .centerY
    row.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(row)
    let lead = row.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading)
    NSLayoutConstraint.activate([
        lead, row.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -trailing),
        row.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
    ])
    return lead
}

/// A section's header row. Its views are made once; `show` sets all it shows, as the outline hands a row set aside when
/// it went back for another section.
final class SectionCell: NSTableCellView, Hoverable {
    static let id = NSUserInterfaceItemIdentifier("scm.section")
    /// Where its rows start, past the inset: under its title, after the chevron.
    static let indent: CGFloat = 16
    private let chevron = NSImageView()
    private let actions = RowActions()
    private let titleField = NSTextField.label(
        "", font: .ui(TextSize.caption, weight: .semibold), color: .secondaryLabelColor)
    private let capsule = CountCapsule()
    private let detailField = NSTextField(labelWithString: "")
    private var open = true
    /// Folded or opened: the chevron turns from what it showed.
    var expanded: Bool {
        get { open }
        set {
            let was = open
            open = newValue
            showChevron()
            if newValue != was { chevron.turn(from: Self.turn(newValue)) }
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
    private func showChevron() { chevron.image = .symbol(open ? "chevron.down" : "chevron.right") }
    init() {
        super.init(frame: .zero)
        identifier = Self.id
        chevron.symbolConfiguration = .chrome(Metrics.iconTiny)
        chevron.contentTintColor = .secondaryLabelColor
        chevron.widthAnchor.constraint(equalToConstant: 10).isActive = true
        pinRow(self, [chevron, titleField, NSView(), actions, detailField, capsule], leading: Metrics.inset)   // the panel's edge, as its header's branch
        showChevron()
    }
    convenience init(title: String, count: Int?, expanded: Bool, actions rowActions: [RowAction]) {
        self.init()
        show(title: title, count: count, expanded: expanded, actions: rowActions)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// All a section's row shows, set again: nothing of the section it showed before stays.
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
    /// Its first action at work (the graph's Refresh): a spinner in its place, which stays when the pointer goes.
    var busy = false {
        didSet {
            guard busy != oldValue else { return }
            (actions.arrangedSubviews.first as? IconButton)?.busy = busy
            if !busy, !hovering { setHover(false) } else { actions.isHidden = false }
        }
    }
}

/// A section's file count on a grey capsule, as in VS Code: a bare "3" next to "+6 −2" ran into it.
private final class CountCapsule: NSView {
    private let field = NSTextField(labelWithString: "")
    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }
    init() {
        super.init(frame: .zero)
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

/// A changed file's row, in the changes or under a commit of the graph. Its views are made once; `show` sets all it
/// shows, as the outline hands a row set aside when it went back for another file.
final class FileCell: NSTableCellView, Hoverable {
    static let id = NSUserInterfaceItemIdentifier("scm.file")
    private let actions = RowActions()
    private(set) var path = ""
    private let icon = NSImageView(), mark = NSImageView()
    private let name = NSTextField(labelWithString: ""), dir = NSTextField(labelWithString: "")
    private let letterField = NSTextField(labelWithString: ""), number = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint?
    /// Under a commit: the lanes below it running on through its files, as in VS Code.
    private var lanes: GraphView?

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        name.font = .ui(TextSize.row)
        name.lineBreakMode = .byTruncatingTail
        dir.font = .ui(TextSize.caption)
        dir.textColor = .secondaryLabelColor
        dir.lineBreakMode = .byTruncatingHead
        dir.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        name.setContentCompressionResistancePriority(.init(400), for: .horizontal)
        letterField.font = .uiMono(TextSize.caption, weight: .semibold)
        letterField.alignment = .center
        letterField.widthAnchor.constraint(equalToConstant: 12).isActive = true
        mark.symbolConfiguration = .chrome(Metrics.iconTiny)
        mark.contentTintColor = .textOrange
        number.font = .uiDigits(TextSize.micro, weight: .semibold)
        number.textColor = .secondaryLabelColor
        leading = pinRow(self, [icon, name, dir, NSView(), actions, mark, number, letterField], leading: Metrics.inset)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `shared`: the branches of other folders of the project that change this file too (`AppModel.sharedFiles`).
    /// `through`: under a commit, the lanes that run on past it and the graph's width.
    func show(
        _ fileChange: FileChange, icon image: NSImage, letter: (String, NSColor), indent: CGFloat,
        actions rowActions: [RowAction],
        shared: [String] = [], commit: Int? = nil, through: (lanes: [Int], width: CGFloat)? = nil
    ) {
        alphaValue = 1   // a discarded file's row faded out (`fadeRows`)
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
        let tip = shared.isEmpty ? nil : String(localized: "Also changed on \(shared.joined(separator: ", "))")
        // Before the letter, where the eye checks a file's state.
        mark.image = tip.map { .symbol("arrow.triangle.merge", $0) }
        mark.isHidden = tip == nil
        // The plan's commit it goes into: the same number as its card over the button.
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
