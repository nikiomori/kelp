import AppKit

/// A sheet on the main window (clone, SSH, first launch); `close()` ends it.
@MainActor
class SheetController: NSWindowController {
    let app: AppModel
    init(app: AppModel, width: CGFloat) {
        self.app = app
        super.init(
            window: NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 10), styleMask: [.titled], backing: .buffered,
                defer: true))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// False when there's no window to put it on. `ended` runs once it's gone.
    func begin(ended: @escaping () -> Void) -> Bool {
        guard let parent = app.workbench.mainWindow ?? NSApp.mainWindow, let sheet = window else { return false }
        parent.beginSheet(sheet) { _ in ended() }
        return true
    }

    package override func close() { if let window { window.sheetParent?.endSheet(window) } }
}
