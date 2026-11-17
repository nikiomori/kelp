import AppKit
import Core

/// The Type Password button in the title bar of a macOS machine's window, which is where dialogs that ask for the
/// password show up (an installer, Privacy & Security). The user never saw the password, and an agent may not type it
/// (`VMType.notForAgents`). kelpd types it from the Keychain, as the button in the machine's tab does. This process
/// doesn't belong to an agent's session, so kelpd treats its request as the user's.
final class PasswordButton: NSButton {
    private var machine = "", socket = ""

    @MainActor static func add(to window: NSWindow, machine: String, folder: URL) {
        // The button's words come from Kelp's own strings, because this app sits in Kelp.app/Contents/Helpers and the
        // translations live in Kelp.app.
        let kelp = Bundle(url: Bundle.main.bundleURL.appendingPathComponent("../../..").standardizedFileURL) ?? .main
        let button = PasswordButton(title: String(localized: "Type Password", bundle: kelp), target: nil, action: nil)
        button.machine = machine
        button.socket =
            folder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("kelp.sock").path
        button.target = button
        button.action = #selector(type)
        button.bezelStyle = .push
        button.controlSize = .small
        button.refusesFirstResponder = true   // typed keys stay with the machine's screen
        button.toolTip = String(
            localized: "Types this machine's password into the field that asks for it, in its window.", bundle: kelp)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: button.fittingSize.width + 12, height: 28))
        button.frame.origin = NSPoint(x: 0, y: (28 - button.fittingSize.height) / 2)
        button.frame.size = button.fittingSize
        box.addSubview(button)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = box
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
    }

    @MainActor @objc private func type() {
        let (machine, socket) = (machine, socket)
        Task { @MainActor in
            do {
                let client = try RPCClient(socket: socket, patience: 2)
                defer { client.close() }
                _ = try await client.call(VMType(name: machine))
            } catch {
                guard let window else { return }
                let alert = NSAlert()
                alert.messageText = (error as? RPCError)?.message ?? error.localizedDescription
                alert.beginSheetModal(for: window) { _ in }
            }
        }
    }
}
