import AppKit
import Core
import DesignKit
import KelpKit

/// The right column of the database tab, like TablePro's inspector. It has three parts. Table shows the table's name,
/// row count, size, comment, columns, what it refers to and its indexes. Row shows the selected row's fields, found by
/// name and edited in place, where a foreign key links to its row. Agent shows what agents ran on this table, and asks
/// an agent about it.
@MainActor
final class DatabaseDetails: NSObject, NSSearchFieldDelegate, NSTextFieldDelegate {
    enum Part: Int { case table, row, agent }

    let view = NSView()
    private let part = CapsuleSegments(
        labels: [String(localized: "Table"), String(localized: "Row"), String(localized: "Agent")],
        name: String(localized: "Show"))
    private let search = NSSearchField()
    private let stack = NSStackView()
    private let empty = EmptyStateView()
    static let width: CGFloat = 264

    /// What the column shows. The tab sets these as its table, selection or runs change.
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
        empty.place(in: view, under: top)
        view.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
    }

    /// Switches to the part asked for and redraws: Row once a row is picked, Table again when none is.
    func show(_ wanted: Part? = nil) {
        if let wanted { part.selectedSegment = wanted.rawValue }
        reload()
    }

    @objc private func partChanged() { reload() }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === search { reload() }
    }

    func reload() {
        for v in stack.arrangedSubviews { v.removeFromSuperview() }
        let which = Part(rawValue: part.selectedSegment) ?? .table
        search.superview?.isHidden = which != .row
        empty.show(nil)
        switch which {
        case .table: tablePart()
        case .row: rowPart()
        case .agent: agentPart()
        }
    }

    // MARK: Table

    private func tablePart() {
        guard let table else { return empty.show(String(localized: "No Table Shown"), symbol: "tablecells") }
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
        guard let row else { return empty.show(String(localized: "No Row Selected"), symbol: "list.bullet.rectangle") }
        let find = search.stringValue.lowercased()
        var shown = 0
        for (i, name) in row.columns.enumerated() where find.isEmpty || name.lowercased().contains(find) {
            let value = row.values.indices.contains(i) ? row.values[i] : nil
            let column = table?.columns.first { $0.name == name }
            add(rowField(i, name, value, column))
            shown += 1
        }
        if shown == 0 { empty.show(String(localized: "No Matching Fields"), symbol: "magnifyingglass") }
    }

    private func rowField(_ index: Int, _ name: String, _ value: String?, _ column: DatabaseSchema.Column?) -> NSView {
        // A long name truncates in its middle; the type stays whole at the right edge.
        let title = small(name)
        title.lineBreakMode = .byTruncatingMiddle
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
        text.widthAnchor.constraint(equalToConstant: Self.width - 2 * Metrics.inset).isActive = true
        return box(parts)
    }

    /// An edit in a field goes into the grid's edits, as if it had been typed in the row's cell.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let text = notification.object as? NSTextField, text !== search, let row else { return }
        let old = row.values.indices.contains(text.tag) ? row.values[text.tag] : nil
        let typed = text.stringValue
        guard typed != DatabaseDetails.readable(old) else { return }   // JSON is shown laid out, so that is no change
        onEdit(text.tag, typed.isEmpty && old == nil ? nil : typed)
    }

    // MARK: Agent

    private func agentPart() {
        if runs.isEmpty {
            empty.show(
                String(localized: "No Agent Runs"), symbol: "clock.arrow.circlepath",
                text: String(localized: "What agents run on this table shows here."))
        }
        for run in runs.prefix(20) {
            let sql = PointerButton(title: run.sql.split(whereSeparator: \.isNewline).joined(separator: " ")) {
                [weak self] in self?.onRun(run)
            }
            sql.font = .uiMono(TextSize.caption)
            sql.lineBreakMode = .byTruncatingTail
            sql.alignment = .left
            sql.widthAnchor.constraint(lessThanOrEqualToConstant: Self.width - 2 * Metrics.inset).isActive = true
            // A finished run's outcome ends with its time; the other states' words carry none.
            let when = run.state == .done ? "" : shortAgo(run.at) + " · "
            add(box([small(when + DatabasePanelRows.outcome(run)), sql]))
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

    private func add(_ view: NSView) { stack.addArrangedSubview(view) }

    private func field(_ title: String, _ value: String, mono: Bool = false) -> NSView {
        let text = NSTextField(wrappingLabelWithString: value)
        text.font = mono ? .uiMono(TextSize.caption) : .ui(TextSize.row)
        text.isSelectable = true
        text.preferredMaxLayoutWidth = Self.width - 2 * Metrics.inset
        return box([small(title), text])
    }

    /// Views one under another, inset from the panel's edges.
    private func box(_ views: [NSView]) -> NSStackView {
        let box = NSStackView(views: views)
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = Metrics.lineGap
        box.edgeInsets = NSEdgeInsets(top: Metrics.gap, left: Metrics.inset, bottom: Metrics.gap, right: Metrics.inset)
        return box
    }

    private func padded(_ view: NSView) -> NSView {
        let box = NSStackView(views: [view])
        box.edgeInsets = NSEdgeInsets(
            top: Metrics.gapWide, left: Metrics.inset, bottom: Metrics.gap, right: Metrics.inset)
        return box
    }

    private func small(_ s: String) -> NSTextField {
        .label(s, font: .ui(TextSize.caption), color: .secondaryLabelColor)
    }

    /// Returns JSON indented, and any other value as it is.
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
