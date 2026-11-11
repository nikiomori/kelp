import AppKit

extension NSAlert {
    /// A question before something that can't be undone, for `runSheet`: the action first (red when `destructive`),
    /// Cancel (or `cancel`) beside it.
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

/// The question as a sheet, awaited: true when the action was picked.
@MainActor
public func confirm(
    _ question: String, detail: String = "", action: String, cancel: String? = nil, destructive: Bool = false
) async -> Bool {
    let alert = NSAlert(question: question, detail: detail, action: action, cancel: cancel, destructive: destructive)
    return await runSheet(alert) == .alertFirstButtonReturn
}

/// One of `choices` from a pop-up in a sheet: its value, nil when cancelled.
@MainActor
public func pick(_ question: String, from choices: [(title: String, value: String)], action: String, width: CGFloat)
    async -> String?
{
    let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: width, height: 26))
    for choice in choices {
        pop.menu?.addItem(withTitle: choice.title, action: nil, keyEquivalent: "").representedObject = choice.value
    }
    let alert = NSAlert(question: question, action: action)
    alert.accessoryView = pop
    return await runSheet(alert) == .alertFirstButtonReturn ? pop.selectedItem?.representedObject as? String : nil
}
