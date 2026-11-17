import Core
import DesignKit
import Foundation
import KelpKit

/// Keeps text that was typed but not saved in the daemon's store, so a crash or a force quit of the window doesn't lose
/// it. A save or Don't Save removes it, so all that's left at launch is what a crash left, and a tab that opens takes
/// its text back.
/// Limit: a buffer over `limit` isn't kept, it would be written whole at every pause in typing.
@MainActor
final class UnsavedBackup {
    static let limit = 2 * 1024 * 1024
    static let prefix = "backup."   // after a launch, the shell looks for keys with this prefix (`UnsavedBackups`)
    private let app: AppModel, key: String, uri: String, workspace: String
    private let waiting = Debounce()
    /// Whether this tab has text in the store. Saves come often, so when nothing is stored, a save doesn't ask the
    /// store to forget anything.
    private var stored: Bool
    /// Text typed but not stored yet, because the pause in typing hasn't come. It is stored at once when the tab goes
    /// away, as when the tab is dropped without a question (its save failed while its workspace closed), because text
    /// that isn't in the store would be lost.
    private var pending: String?

    init(app: AppModel, uri: String) {
        self.app = app
        self.uri = uri
        workspace = app.workbench.workspaceId ?? ""
        key = Self.prefix + workspace + "." + uri
        stored = !app.uiState.strings(key).isEmpty
    }

    var text: String? {
        let parts = app.uiState.strings(key)
        return parts.count == 3 ? parts[2] : nil
    }

    /// Stores `text` after a pause in typing. The store write runs on the main thread.
    func keep(_ text: String) {
        pending = text
        waiting.after(1) { [weak self] in self?.flush() }
    }

    private func flush() {
        guard let text = pending else { return }
        pending = nil
        guard text.utf8.count <= Self.limit else { return drop() }
        stored = true
        write(.array([.string(uri), .string(workspace), .string(text)]))
    }

    isolated deinit { flush() }

    func drop() {
        waiting.cancel()
        pending = nil
        guard stored else { return }
        stored = false
        write(nil)
    }

    private func write(_ value: JSONValue?) {
        Task { [app, key] in _ = await app.uiState.save(key, value) }
    }
}
