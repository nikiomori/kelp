import AppKit
import Core
import DesignKit
import KelpKit

/// The database tab's right column, as TablePro's inspector: Table (its rows, size, comment, columns, indexes,
/// CREATE TABLE), Row (the selected row's fields, found by name, edited in place; a foreign key a link to its row),
/// Agent (what agents ran on this table, and asking one about it).
@MainActor
final class DatabaseDetails: NSObject, NSSearchFieldDelegate, NSTextFieldDelegate {
    enum Part: Int { case table, row, agent }

    let view = NSView()
    private let part = NSSegmentedControl(
        labels: [String(localized: "Table"), String(localized: "Row"), String(localized: "Agent")],
        trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let stack = NSStackView()
    static let width: CGFloat = 264

    /// What it shows: set by the tab as its table, selection or runs change.
    var table: DatabaseSchema.Table?
    var row: (index: Int, columns: [String], values: [String?])?
    var runs: [DatabaseRun] = []
    var agentName: String?
    var editable = false
    var onEdit: (_ column: Int, _ value: String?) -> Void = { _, _ in }
    var onFollow: (_ table: String, _ column: String, _ value: String) -> Void = { _, _, _ in }
    var onRun: (DatabaseRun) -> Void = { _ in }
    var onAsk: () -> Void = {}

    override init() {
        super.init()
        part.selectedSegment = 0
        part.controlSize = .small
        part.target = self
        part.action = #selector(partChanged)
        search.placeholderString = String(localized: "Find a field")
        search.controlSize = .small
        search.delegate = self
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let flipped = FlippedView()
        flipped.pin(stack)
        scroll.documentView = flipped
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let top = NSStackView(views: [part])
        top.edgeInsets = NSEdgeInsets(top: Metrics.gap, left: 0, bottom: 0, right: 0)
        let find = NSStackView(views: [search])
        find.edgeInsets = NSEdgeInsets(
            top: Metrics.gap, left: Metrics.gapWide, bottom: Metrics.gap, right: Metrics.gapWide)
        let column = NSStackView(views: [top, find, scroll])
        column.orientation = .vertical
        column.spacing = 0
        for v in [find, scroll] { v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        view.pin(column)
        view.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
    }

    /// The Row part once a row is picked; Table again when none is.
    func show(_ wanted: Part? = nil) {
        if let wanted { part.selectedSegment = wanted.rawValue }
        reload()
    }

    @objc private func partChanged() { reload() }
    func controlTextDidChange(_ n: Notification) { if n.object as? NSSearchField === search { reload() } }

    func reload() {
        for v in stack.arrangedSubviews { v.removeFromSuperview() }
        let which = Part(rawValue: part.selectedSegment) ?? .table
        search.superview?.isHidden = which != .row
        switch which {
        case .table: tablePart()
        case .row: rowPart()
        case .agent: agentPart()
        }
    }

    // MARK: Table

    private func tablePart() {
        guard let table else { return add(note(String(localized: "No Table Shown"))) }
        add(field(String(localized: "Name"), table.name, mono: true))
        if table.kind == "view" { add(field(String(localized: "Kind"), String(localized: "View"))) }
        if let rows = table.rows { add(field(String(localized: "Rows"), "≈ " + rows.formatted())) }
        if let bytes = table.bytes {
            add(
                field(
                    String(localized: "Size, with indexes"),
                    DesignKit.bytes(bytes, file: true)))
        }
        if let comment = table.comment { add(field(String(localized: "Comment"), comment)) }
        let keys = table.columns.filter(\.primary).map(\.name)
        add(
            field(
                String(localized: "Columns"),
                "\(table.columns.count)" + (keys.isEmpty ? "" : " · key " + keys.joined(separator: ", "))))
        let refs = table.columns.compactMap { column in column.references.map { "\(column.name) → \($0)" } }
        if !refs.isEmpty { add(field(String(localized: "Refers to"), refs.joined(separator: "\n"), mono: true)) }
        if !table.indexes.isEmpty {
            add(field(String(localized: "Indexes"), table.indexes.joined(separator: "\n"), mono: true))
        }
    }

    // MARK: Row

    private func rowPart() {
        guard let row else { return add(note(String(localized: "No Row Selected"))) }
        let find = search.stringValue.lowercased()
        var shown = 0
        for (i, name) in row.columns.enumerated() where find.isEmpty || name.lowercased().contains(find) {
            let value = row.values.indices.contains(i) ? row.values[i] : nil
            let column = table?.columns.first { $0.name == name }
            add(rowField(i, name, value, column))
            shown += 1
        }
        if shown == 0 { add(note(String(localized: "No Matching Fields"))) }
    }

    private func rowField(_ index: Int, _ name: String, _ value: String?, _ column: DatabaseSchema.Column?) -> NSView {
        // The name gives way in its middle; the type stays whole at the right edge.
        let title = small(name)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let kind = small(
            [column?.type.lowercased(), column?.primary == true ? "key" : nil].compactMap { $0 }
                .joined(separator: " · "))
        kind.setContentCompressionResistancePriority(.required, for: .horizontal)
        let head = NSStackView(views: [title, NSView(), kind])
        head.spacing = Metrics.gap
        head.widthAnchor.constraint(equalToConstant: Self.width - 2 * Metrics.inset).isActive = true
        var parts: [NSView] = [head]
        if let ref = column?.references, let value, case let target = ref.split(separator: "."), target.count == 2 {
            let link = PointerButton(title: "\(value) → \(target[0])") { [weak self] in
                self?.onFollow(String(target[0]), String(target[1]), value)
            }
            link.contentTintColor = .linkColor
            link.font = .uiMono(TextSize.caption)
            link.lineBreakMode = .byTruncatingMiddle
            link.underlinesOnHover = true
            parts.append(link)
        }
        let multiline =
            (value?.count ?? 0) > 40 || value?.contains("\n") == true || value?.first == "{" || value?.first == "["
        let text = multiline ? NSTextField(wrappingLabelWithString: "") : NSTextField()
        text.stringValue = DatabaseDetails.readable(value)
        text.placeholderString = value == nil ? "NULL" : nil
        if value == nil { text.stringValue = "" }
        text.font = .uiMono(TextSize.caption)
        text.isEditable = editable
        text.isSelectable = true
        text.isBezeled = editable
        text.drawsBackground = editable
        text.tag = index
        text.delegate = self
        text.preferredMaxLayoutWidth = Self.width - 2 * Metrics.inset
        parts.append(text)
        let box = NSStackView(views: parts)
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = Metrics.lineGap
        box.edgeInsets = NSEdgeInsets(top: Metrics.gap, left: Metrics.inset, bottom: Metrics.gap, right: Metrics.inset)
        text.widthAnchor.constraint(equalToConstant: Self.width - 2 * Metrics.inset).isActive = true
        return box
    }

    /// An edit in a field goes to the grid's edits, as one typed in its cell.
    func controlTextDidEndEditing(_ n: Notification) {
        guard let text = n.object as? NSTextField, text !== search, let row else { return }
        let old = row.values.indices.contains(text.tag) ? row.values[text.tag] : nil
        let typed = text.stringValue
        guard typed != DatabaseDetails.readable(old) else { return }   // shown laid out (JSON): not a change
        onEdit(text.tag, typed.isEmpty && old == nil ? nil : typed)
    }

    // MARK: Agent

    private func agentPart() {
        if runs.isEmpty { add(note(String(localized: "No Agent Has Run Anything on It"))) }
        for run in runs.prefix(20) {
            let sql = PointerButton(title: run.sql.split(whereSeparator: \.isNewline).joined(separator: " ")) {
                [weak self] in self?.onRun(run)
            }
            sql.font = .uiMono(TextSize.caption)
            sql.lineBreakMode = .byTruncatingTail
            sql.alignment = .left
            let box = NSStackView(views: [small("\(shortAgo(run.at)) · \(DatabasePanelRows.outcome(run))"), sql])
            box.orientation = .vertical
            box.alignment = .leading
            box.spacing = Metrics.lineGap
            box.edgeInsets = NSEdgeInsets(
                top: Metrics.gap, left: Metrics.inset, bottom: Metrics.gap, right: Metrics.inset)
            sql.widthAnchor.constraint(lessThanOrEqualToConstant: Self.width - 2 * Metrics.inset).isActive = true
            add(box)
        }
        if let agentName {
            let ask = ClosureButton(title: String(localized: "Ask \(agentName) About This Table")) { [weak self] in
                self?.onAsk()
            }
            ask.controlSize = .small
            add(padded(ask))
        }
    }

    // MARK: Parts

    private func add(_ v: NSView) { stack.addArrangedSubview(v) }

    private func field(_ title: String, _ value: String, mono: Bool = false) -> NSView {
        let text = NSTextField(wrappingLabelWithString: value)
        text.font = mono ? .uiMono(TextSize.caption) : .ui(TextSize.row)
        text.isSelectable = true
        text.preferredMaxLayoutWidth = Self.width - 2 * Metrics.inset
        let box = NSStackView(views: [small(title), text])
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = Metrics.lineGap
        box.edgeInsets = NSEdgeInsets(top: Metrics.gap, left: Metrics.inset, bottom: Metrics.gap, right: Metrics.inset)
        return box
    }

    private func padded(_ v: NSView) -> NSView {
        let box = NSStackView(views: [v])
        box.edgeInsets = NSEdgeInsets(
            top: Metrics.gapWide, left: Metrics.inset, bottom: Metrics.gap, right: Metrics.inset)
        return box
    }

    private func note(_ s: String) -> NSView {
        let label = NSTextField(labelWithString: s)
        label.font = .ui(TextSize.row)
        label.textColor = .tertiaryLabelColor
        return padded(label)
    }

    private func small(_ s: String) -> NSTextField {
        let label = NSTextField(labelWithString: s)
        label.font = .ui(TextSize.caption)
        label.textColor = .tertiaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    /// JSON indented; the rest as it is.
    static func readable(_ value: String?) -> String {
        guard let value, value.first == "{" || value.first == "[" else { return value ?? "" }
        do {
            let object = try JSONSerialization.jsonObject(with: Data(value.utf8))
            let data = try JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        } catch { return value }
    }
}
