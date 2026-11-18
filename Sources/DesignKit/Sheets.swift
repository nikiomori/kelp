import AppKit

/// The window a sheet goes on. Key and main are nil while Kelp isn't the active app, but the sheet still belongs on
/// its window. A window that already shows a sheet queues the next.
@MainActor
private var sheetWindow: NSWindow? {
    NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
}

/// Runs an alert as a sheet on the front window and waits (native, with no nested modal loop). Every question in the
/// app goes here.
@MainActor
public func runSheet(_ alert: NSAlert) async -> NSApplication.ModalResponse {
    guard let window = sheetWindow else { return alert.runModal() }
    return await withCheckedContinuation { c in alert.beginSheetModal(for: window) { c.resume(returning: $0) } }
}

/// Runs a window of our own (a form) as a sheet on the front window and waits. Its buttons end it with
/// `sheetParent?.endSheet(_:returnCode:)`. Returns `.abort` when there's no window to put it on.
@MainActor
public func runSheet(_ sheet: NSWindow) async -> NSApplication.ModalResponse {
    guard let window = sheetWindow else { return .abort }
    return await withCheckedContinuation { c in window.beginSheet(sheet) { c.resume(returning: $0) } }
}

/// Runs a save panel as a sheet on the front window and waits.
@MainActor
public func runSheet(_ savePanel: NSSavePanel) async -> NSApplication.ModalResponse {
    guard let window = sheetWindow else { return savePanel.runModal() }
    return await withCheckedContinuation { c in savePanel.beginSheetModal(for: window) { c.resume(returning: $0) } }
}

/// Asks a one-field question (rename, go to line…).
@MainActor
public func prompt(_ title: String, _ info: String, initial: String = "", action: String? = nil) async -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = info
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: Metrics.alertAccessory, height: 24))
    field.stringValue = initial
    alert.accessoryView = field
    alert.addButton(withTitle: action ?? String(localized: "OK"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    alert.window.initialFirstResponder = field
    return await runSheet(alert) == .alertFirstButtonReturn ? field.stringValue : nil
}
