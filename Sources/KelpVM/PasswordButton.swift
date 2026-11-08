import AppKit
import Core

/// Type Password in a macOS machine's title bar, where the dialog that asks for it is (an installer, Privacy &
/// Security): the user never saw the password, and an agent may not type it (`VMType.notForAgents`). kelpd types it
/// from the Keychain, as the button in the machine's tab does; this process isn't a session's: it asks as the user.
final class PasswordButton: NSButton {
    private var machine = "", socket = ""

    @MainActor static func add(to window: NSWindow, machine: String, folder: URL) {
        // Kelp's own words: this app sits in Kelp.app/Contents/Helpers, its strings in Kelp.app.
        let kelp = Bundle(url: Bundle.main.bundleURL.appendingPathComponent("../../..").standardizedFileURL) ?? .main
        let button = PasswordButton(title: String(localized: "Type Password", bundle: kelp), target: nil, action: nil)
        button.machine = machine
        button.socket =
            folder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("kelp.sock").path
        button.target = button
        button.action = #selector(type)
        button.bezelStyle = .push
        button.controlSize = .small
        button.refusesFirstResponder = true   // keys stay with the machine's screen
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
