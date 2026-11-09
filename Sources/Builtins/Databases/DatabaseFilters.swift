import AppKit
import Core
import DesignKit
import KelpKit

/// The filter over a table's rows (⇧⌘F), as TablePro's: rows of column ▾ condition ▾ value, each with a box that turns
/// it on, + and −; Match all or any; Raw SQL in the column's list makes its row a WHERE of its own. Apply (↩) reads
/// the rows again with it.
@MainActor
final class DatabaseFilters: NSObject, NSTextFieldDelegate {
    struct Rule: Equatable {
        var on = true, column = "", op = Condition.equal, value = ""
    }
    enum Condition: String, CaseIterable {
        case equal = "=", notEqual = "≠", contains = "contains", notContains = "doesn't contain",
            startsWith = "starts with", greater = ">", less = "<", isNull = "is NULL", isNotNull = "is not NULL",
            isIn = "in"

        var takesValue: Bool { self != .isNull && self != .isNotNull }
    }
    static let raw = String(localized: "Raw SQL")

    let view = NSStackView()
    private var rules: [Rule] = [Rule()]
    private var columns: [String] = []
    private var engine: DatabaseInfo.Engine = .sqlite
    private let any = NSPopUpButton()
    var onApply: (String) -> Void = { _ in }

    override init() {
        super.init()
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = Metrics.gap
        view.edgeInsets = NSEdgeInsets(top: Metrics.gap, left: Metrics.inset, bottom: Metrics.gap, right: Metrics.inset)
        any.addItems(withTitles: [String(localized: "Match All"), String(localized: "Match Any")])
        any.controlSize = .small
        view.isHidden = true
    }

    /// For a table's columns; rules for columns it lacks go.
    func use(columns: [String], engine: DatabaseInfo.Engine) {
        self.columns = columns
        self.engine = engine
        rules = rules.filter { $0.column == Self.raw || columns.contains($0.column) || $0.column.isEmpty }
        if rules.isEmpty { rules = [Rule()] }
        lay()
    }

    /// A condition from a cell's menu: its column, condition and value as a rule to change.
    func add(column: String, op: Condition, value: String?) {
        let rule = Rule(column: column, op: op, value: value ?? "")
        if rules.count == 1, rules[0].value.isEmpty, rules[0].op.takesValue {
            rules = [rule]
        } else {
            rules.append(rule)
        }
        view.isHidden = false
        lay()
        apply()
    }

    func clear() {
        rules = [Rule()]
        lay()
    }

    var isActive: Bool { !condition.isEmpty }

    /// The WHERE the rules that are on make: "status = 'pending' AND note IS NULL".
    var condition: String {
        let parts = rules.filter(\.on).compactMap(sql)
        guard !parts.isEmpty else { return "" }
        return parts.count == 1
            ? parts[0] : parts.map { "(\($0))" }.joined(separator: any.indexOfSelectedItem == 1 ? " OR " : " AND ")
    }

    private func sql(_ r: Rule) -> String? {
        if r.column == Self.raw { return r.value.trimmingCharacters(in: .whitespaces).isEmpty ? nil : r.value }
        guard columns.contains(r.column) else { return nil }
        let name = DatabaseEdits.name(r.column, engine), v = r.value
        if r.op.takesValue, v.isEmpty { return nil }
        let like = engine == .postgres ? "ILIKE" : "LIKE"
        switch r.op {
        case .equal: return "\(name) = " + DatabaseEdits.literal(v, engine)
        case .notEqual: return "\(name) <> " + DatabaseEdits.literal(v, engine)
        case .contains: return "\(name) \(like) " + DatabaseEdits.literal("%\(v)%", engine)
        case .notContains: return "\(name) NOT \(like) " + DatabaseEdits.literal("%\(v)%", engine)
        case .startsWith: return "\(name) \(like) " + DatabaseEdits.literal("\(v)%", engine)
        case .greater: return "\(name) > " + DatabaseEdits.literal(v, engine)
        case .less: return "\(name) < " + DatabaseEdits.literal(v, engine)
        case .isNull: return "\(name) IS NULL"
        case .isNotNull: return "\(name) IS NOT NULL"
        case .isIn:
            let items = v.split(separator: ",").map {
                DatabaseEdits.literal($0.trimmingCharacters(in: .whitespaces), engine)
            }
            return "\(name) IN (" + items.joined(separator: ", ") + ")"
        }
    }

    // MARK: Rows

    private func lay() {
        for v in view.arrangedSubviews { v.removeFromSuperview() }
        for (i, rule) in rules.enumerated() { view.addArrangedSubview(line(i, rule)) }
    }

    private func line(_ i: Int, _ rule: Rule) -> NSView {
        let on = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
        on.tag = i
        on.state = rule.on ? .on : .off
        let column = NSPopUpButton()
        column.controlSize = .small
        column.addItems(withTitles: columns + [Self.raw])
        column.selectItem(withTitle: rule.column.isEmpty ? (columns.first ?? Self.raw) : rule.column)
        if rule.column.isEmpty { rules[i].column = column.titleOfSelectedItem ?? Self.raw }
        column.tag = i
        column.target = self
        column.action = #selector(columnPicked(_:))
        let op = NSPopUpButton()
        op.controlSize = .small
        op.addItems(withTitles: Condition.allCases.map(\.rawValue))
        op.selectItem(withTitle: rule.op.rawValue)
        op.tag = i
        op.target = self
        op.action = #selector(opPicked(_:))
        let raw = rules[i].column == Self.raw
        op.isHidden = raw
        let value = NSTextField(string: rule.value)
        value.controlSize = .small
        value.font = .uiMono(11.5)
        value.placeholderString =
            raw ? "status = 'paid' AND total > 10" : rule.op == .isIn ? "a, b, c" : String(localized: "Value")
        value.isHidden = !raw && !rule.op.takesValue
        value.tag = i
        value.delegate = self
        let remove = IconButton(.symbol("minus"), tip: String(localized: "Remove This Condition")) { [weak self] in
            self?.remove(i)
        }
        let more = IconButton(.symbol("plus"), tip: String(localized: "Add a Condition")) { [weak self] in
            self?.rules.insert(Rule(), at: i + 1)
            self?.lay()
        }
        var views: [NSView] = [on, column, op, value, remove, more]
        if i == 0 {
            let apply = ClosureButton(title: String(localized: "Apply")) { [weak self] in self?.apply() }
            apply.controlSize = .small
            apply.bezelStyle = .push
            apply.keyEquivalent = "\r"
            views += [any, apply]
        }
        let row = NSStackView(views: views)
        row.spacing = Metrics.gap
        value.setContentHuggingPriority(.defaultLow, for: .horizontal)
        value.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        return row
    }

    private func remove(_ i: Int) {
        rules.remove(at: i)
        if rules.isEmpty {
            rules = [Rule()]
            view.isHidden = true
        }
        lay()
        apply()
    }

    @objc private func toggled(_ sender: NSButton) {
        rules[sender.tag].on = sender.state == .on
        apply()
    }
    @objc private func columnPicked(_ sender: NSPopUpButton) {
        rules[sender.tag].column = sender.titleOfSelectedItem ?? ""
        lay()
    }
    @objc private func opPicked(_ sender: NSPopUpButton) {
        rules[sender.tag].op = Condition.allCases[max(0, sender.indexOfSelectedItem)]
        lay()
        if !rules[sender.tag].op.takesValue { apply() }
    }
    func controlTextDidChange(_ n: Notification) {
        guard let field = n.object as? NSTextField, rules.indices.contains(field.tag) else { return }
        rules[field.tag].value = field.stringValue
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        apply()
        return true
    }

    func apply() { onApply(condition) }
}
