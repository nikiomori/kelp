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
        status.font = .ui(TextSize.caption)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Begins the sheet, and returns false when there's no window to put it on. `ended` runs once the sheet is gone.
    func begin(ended: @escaping () -> Void) -> Bool {
        guard let parent = app.workbench.activeWindow ?? NSApp.mainWindow, let sheet = window else { return false }
        parent.beginSheet(sheet) { _ in ended() }
        return true
    }

    /// Shows `text` on the status line (red for an `error`), or hides the line for nil.
    func say(_ text: String?, error: Bool = false) {
        status.isHidden = text == nil
        status.stringValue = text ?? ""
        status.textColor = error ? .textRed : .secondaryLabelColor
    }

    override func close() { if let window { window.sheetParent?.endSheet(window) } }
}
