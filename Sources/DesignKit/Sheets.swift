import AppKit

/// The window a sheet goes on: key / main are nil while Kelp isn't the active app, the sheet still belongs on its window.
/// One that already shows a sheet queues the next.
@MainActor
private var sheetWindow: NSWindow? {
    NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
}

/// An alert as a sheet on the front window, awaited (native, no nested modal loop). Every question in the app goes here.
@MainActor
public func runSheet(_ a: NSAlert) async -> NSApplication.ModalResponse {
    guard let window = sheetWindow else { return a.runModal() }
    return await withCheckedContinuation { c in a.beginSheetModal(for: window) { c.resume(returning: $0) } }
}

/// A window of our own (a form) as a sheet on the front window, awaited; its buttons end it with
/// `sheetParent?.endSheet(_:returnCode:)`. `.abort` when there's no window to put it on.
@MainActor
public func runSheet(_ sheet: NSWindow) async -> NSApplication.ModalResponse {
    guard let window = sheetWindow else { return .abort }
    return await withCheckedContinuation { c in window.beginSheet(sheet) { c.resume(returning: $0) } }
}

/// A save panel as a sheet on the front window, awaited.
@MainActor
public func runSheet(_ p: NSSavePanel) async -> NSApplication.ModalResponse {
    guard let window = sheetWindow else { return p.runModal() }
    return await withCheckedContinuation { c in p.beginSheetModal(for: window) { c.resume(returning: $0) } }
}

/// A one-field question (rename, go to line…).
@MainActor
public func prompt(_ title: String, _ info: String, initial: String = "", action: String? = nil) async -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = info
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    field.stringValue = initial
    alert.accessoryView = field
    alert.addButton(withTitle: action ?? String(localized: "OK"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    alert.window.initialFirstResponder = field
    return await runSheet(alert) == .alertFirstButtonReturn ? field.stringValue : nil
}
