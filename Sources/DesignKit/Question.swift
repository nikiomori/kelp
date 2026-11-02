import AppKit

extension NSAlert {
    /// A question before something that can't be undone, for `runSheet`: the action first, Cancel beside it.
    public convenience init(question: String, detail: String = "", action: String) {
        self.init()
        messageText = question
        informativeText = detail
        addButton(withTitle: action)
        addButton(withTitle: String(localized: "Cancel"))
    }
}
