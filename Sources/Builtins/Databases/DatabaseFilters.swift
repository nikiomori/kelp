import AppKit
import Core
import DesignKit
import KelpKit

/// The filter over a table's rows (Filters), like TablePro's. Each rule is a row of column ▾, condition ▾ and value,
/// with a checkbox that turns the rule on and + and − buttons (between takes two values, from and to); Match all or
/// any joins the rules. Choosing Raw SQL in
/// the column list turns that row into a WHERE clause of its own. Apply (↩) reads the rows again with the filter.
@MainActor
final class DatabaseFilters: NSObject, NSTextFieldDelegate {
    struct Rule: Equatable {
        var on = true, column = "", op = Condition.equal, value = ""
        /// Where between ends.
        var to = ""
    }
    enum Condition: String, CaseIterable {
        case equal = "=", notEqual = "≠", contains = "contains", notContains = "doesn’t contain",
            startsWith = "starts with", greater = ">", less = "<", atLeast = "≥", atMost = "≤", between = "between",
            isNull = "is NULL", isNotNull = "is not NULL", isEmpty = "is empty", isIn = "in"

        var takesValue: Bool { ![.isNull, .isNotNull, .isEmpty].contains(self) }
        /// The condition as the pop-up words it. The signs are the same in every language.
        var title: String {
            switch self {
            case .contains: String(localized: "contains")
            case .notContains: String(localized: "doesn’t contain")
            case .startsWith: String(localized: "starts with")
            case .isNull: String(localized: "is NULL")
            case .isNotNull: String(localized: "is not NULL")
            case .isEmpty: String(localized: "is empty")
            case .between: String(localized: "between")
            case .isIn: String(localized: "in")
            default: rawValue
            }
        }
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
        any.setAccessibilityLabel(String(localized: "Conditions to Match"))
        view.isHidden = true
    }

    /// Takes a table's columns; rules for columns the table lacks are dropped.
    func use(columns: [String], engine: DatabaseInfo.Engine) {
        self.columns = columns
        self.engine = engine
        rules = rules.filter { $0.column == Self.raw || columns.contains($0.column) || $0.column.isEmpty }
        if rules.isEmpty { rules = [Rule()] }
        lay()
    }

    /// Adds a condition picked from a cell's menu (its column, condition and value) as a rule the user can change.
    func add(column: String, op: Condition, value: String?, to: String = "") {
        let rule = Rule(column: column, op: op, value: value ?? "", to: to)
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

    /// The WHERE clause made by the rules that are on, such as "status = 'pending' AND note IS NULL".
    var condition: String {
        let parts = rules.filter(\.on).compactMap(sql)
        guard !parts.isEmpty else { return "" }
        return parts.count == 1
            ? parts[0] : parts.map { "(\($0))" }.joined(separator: any.indexOfSelectedItem == 1 ? " OR " : " AND ")
    }

    private func sql(_ rule: Rule) -> String? {
        if rule.column == Self.raw { return rule.value.trimmingCharacters(in: .whitespaces).isEmpty ? nil : rule.value }
        guard columns.contains(rule.column) else { return nil }
        let name = engine.table(rule.column), v = rule.value
        if rule.op.takesValue, v.isEmpty || (rule.op == .between && rule.to.isEmpty) { return nil }
        let like = engine.likeAnyCase
        switch rule.op {
        case .equal: return "\(name) = " + engine.literal(v)
        case .notEqual: return "\(name) <> " + engine.literal(v)
        case .contains: return "\(name) \(like) " + engine.literal("%\(v)%")
        case .notContains: return "\(name) NOT \(like) " + engine.literal("%\(v)%")
        case .startsWith: return "\(name) \(like) " + engine.literal("\(v)%")
        case .greater: return "\(name) > " + engine.literal(v)
        case .less: return "\(name) < " + engine.literal(v)
        case .atLeast: return "\(name) >= " + engine.literal(v)
        case .atMost: return "\(name) <= " + engine.literal(v)
        case .between: return "\(name) BETWEEN \(engine.literal(v)) AND \(engine.literal(rule.to))"
        case .isNull: return "\(name) IS NULL"
        case .isNotNull: return "\(name) IS NOT NULL"
        case .isEmpty: return "\(name) = ''"
        case .isIn:
            let items = v.split(separator: ",").map {
                engine.literal($0.trimmingCharacters(in: .whitespaces))
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
        on.setAccessibilityLabel(String(localized: "Use This Condition"))
        let column = NSPopUpButton()
        column.controlSize = .small
        column.addItems(withTitles: columns + [Self.raw])
        column.selectItem(withTitle: rule.column.isEmpty ? (columns.first ?? Self.raw) : rule.column)
        if rule.column.isEmpty { rules[i].column = column.titleOfSelectedItem ?? Self.raw }
        column.setAccessibilityLabel(String(localized: "Column"))
        column.tag = i
        column.target = self
        column.action = #selector(columnPicked(_:))
        let op = NSPopUpButton()
        op.controlSize = .small
        op.addItems(withTitles: Condition.allCases.map(\.title))
        op.selectItem(withTitle: rule.op.title)
        op.setAccessibilityLabel(String(localized: "Condition"))
        op.tag = i
        op.target = self
        op.action = #selector(opPicked(_:))
        let raw = rules[i].column == Self.raw
        op.isHidden = raw
        let value = NSTextField(string: rule.value)
        value.controlSize = .small
        value.font = .uiMono(TextSize.caption)
        value.placeholderString =
            raw ? "status = 'paid' AND total > 10" : rule.op == .isIn ? "a, b, c" : String(localized: "Value")
        value.isHidden = !raw && !rule.op.takesValue
        value.setAccessibilityLabel(raw ? Self.raw : String(localized: "Value"))
        value.tag = i
        value.delegate = self
        let to = NSTextField(string: rule.to)   // between's second value
        to.controlSize = .small
        to.font = .uiMono(TextSize.caption)
        to.placeholderString = String(localized: "To")
        to.isHidden = raw || rule.op != .between
        to.setAccessibilityLabel(String(localized: "To"))
        to.identifier = Self.toId
        to.tag = i
        to.delegate = self
        if rule.op == .between { value.placeholderString = String(localized: "From") }
        let remove = IconButton(.symbol("minus"), tip: String(localized: "Remove This Condition")) { [weak self] in
            self?.remove(i)
        }
        let more = IconButton(.symbol("plus"), tip: String(localized: "Add a Condition")) { [weak self] in
            self?.rules.insert(Rule(), at: i + 1)
            self?.lay()
        }
        var views: [NSView] = [on, column, op, value, to, remove, more]
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
        to.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        return row
    }

    private static let toId = NSUserInterfaceItemIdentifier("filter.to")

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
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, rules.indices.contains(field.tag) else { return }
        if field.identifier == Self.toId {
            rules[field.tag].to = field.stringValue
        } else {
            rules[field.tag].value = field.stringValue
        }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        apply()
        return true
    }

    func apply() { onApply(condition) }
}
