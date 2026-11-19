import AppKit

extension NSAlert {
    /// A question before something that can't be undone, for `runSheet`: the action first (red when `destructive`),
    /// with Cancel (or `cancel`) beside it.
    public convenience init(
        question: String, detail: String = "", action: String, cancel: String? = nil, destructive: Bool = false
    ) {
        self.init()
        messageText = question
        informativeText = detail
        addButton(withTitle: action).hasDestructiveAction = destructive
        addButton(withTitle: cancel ?? String(localized: "Cancel"))
    }
}

/// Asks the question as a sheet and waits; returns true when the action was picked.
@MainActor
public func confirm(
    _ question: String, detail: String = "", action: String, cancel: String? = nil, destructive: Bool = false
) async -> Bool {
    let alert = NSAlert(question: question, detail: detail, action: action, cancel: cancel, destructive: destructive)
    return await runSheet(alert) == .alertFirstButtonReturn
}

/// Asks for one of `choices` from a pop-up in a sheet, and returns its value, or nil when cancelled.
@MainActor
public func pick(
    _ question: String, from choices: [(title: String, value: String)], action: String,
    width: CGFloat = Metrics.alertAccessory
) async -> String? {
    let pop = accessory(NSPopUpButton(), width: width)
    for choice in choices {
        pop.menu?.addItem(withTitle: choice.title, action: nil, keyEquivalent: "").representedObject = choice.value
    }
    let alert = NSAlert(question: question, action: action)
    alert.accessoryView = pop
    return await runSheet(alert) == .alertFirstButtonReturn ? pop.selectedItem?.representedObject as? String : nil
}

/// Asks for a secret (an API key) in a sheet: a field that hides what's typed. Returns it, or nil when cancelled.
@MainActor
public func askSecret(_ question: String, detail: String, action: String, placeholder: String) async -> String? {
    let field = accessory(NSSecureTextField())
    field.placeholderString = placeholder
    let alert = NSAlert(question: question, detail: detail, action: action)
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    return await runSheet(alert) == .alertFirstButtonReturn ? field.stringValue : nil
}

/// A question sheet's field or pop-up: as wide as every other question's (`Metrics.alertAccessory`), and as tall as it
/// draws itself, so a rename, a key and a choice stand alike.
@MainActor
func accessory<Field: NSView>(_ field: Field, width: CGFloat = Metrics.alertAccessory) -> Field {
    field.frame.size = NSSize(width: width, height: field.fittingSize.height)
    return field
}

extension NSScrollView {
    /// Read-only monospaced text for a question's accessory (the commands a file runs, a whole error), scrollable
    /// when long. `lines` sizes it, up to 220 pt.
    public static func readOnly(_ text: String, lines: Int, width: CGFloat = Metrics.alertAccessory) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: min(220, CGFloat(max(lines, 1)) * 16 + 10))
        scroll.borderType = .bezelBorder
        if let view = scroll.documentView as? NSTextView {
            view.string = text
            view.font = .uiMono(TextSize.caption)
            view.isEditable = false
            view.textContainerInset = NSSize(width: 4, height: 4)
        }
        return scroll
    }
}
