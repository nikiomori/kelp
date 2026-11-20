import AppKit
import DesignKit

/// A sheet on the main window (clone, SSH, first launch). `close()` ends it.
@MainActor
class SheetController: NSWindowController {
    let app: AppModel
    /// The line under the form: what the sheet is doing, or what went wrong (`say`).
    let status = NSTextField(wrappingLabelWithString: "")
    init(app: AppModel, width: CGFloat) {
        self.app = app
        super.init(
            window: NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 10), styleMask: [.titled], backing: .buffered,
                defer: true))
        status.textColor = .secondaryLabelColor
        status.font = .uiDigits(TextSize.caption)   // git's percentages and counts change many times a second
        status.cell?.truncatesLastVisibleLine = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Begins the sheet, and returns false when there's no window to put it on. `ended` runs once the sheet is gone.
    func begin(ended: @escaping () -> Void) -> Bool {
        guard let parent = app.workbench.activeWindow ?? NSApp.mainWindow, let sheet = window else { return false }
        parent.beginSheet(sheet) { _ in ended() }
        return true
    }

    /// Shows `text` on the status line (red for an `error`), or hides the line for nil. What the sheet is doing keeps
    /// to one line, so a long progress line doesn't make the sheet hop; an error wraps, to be read whole.
    func say(_ text: String?, error: Bool = false) {
        // A progress line in the line's place leaves the sheet's height as it is, so it isn't measured again.
        let resizes = error || status.isHidden != (text == nil) || status.maximumNumberOfLines != 1
        status.maximumNumberOfLines = error ? 0 : 1
        status.lineBreakMode = error ? .byWordWrapping : .byTruncatingTail
        status.isHidden = text == nil
        status.stringValue = text ?? ""
        status.textColor = error ? .textRed : .secondaryLabelColor
        if resizes { SheetForm.fit(window) }
    }

    override func close() { if let window { window.sheetParent?.endSheet(window) } }
}
