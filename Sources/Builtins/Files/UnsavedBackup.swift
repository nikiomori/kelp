import Core
import DesignKit
import Foundation
import KelpKit

/// Text typed and not saved, kept in the daemon's store so a crash or a force quit of the window doesn't take it. A save
/// or a Don't Save takes it away, so all that's left at launch is what a crash left, and a tab that opens takes it back.
/// Limit: a buffer over `limit` isn't kept, it would be written whole at every pause in typing.
@MainActor
final class UnsavedBackup {
    static let limit = 2 * 1024 * 1024
    static let prefix = "backup."   // the shell looks there after a launch: `UnsavedBackups.prefix`
    private let app: AppModel, key: String, uri: String, workspace: String
    private let waiting = Debounce()
    /// Something of this tab's is in the store: a save, which comes often, asks it to forget nothing otherwise.
    private var stored: Bool
    /// Typed and not kept yet (the pause hasn't come): kept at once when the tab goes, dropped without a question (its
    /// save failed while its workspace went): what isn't in the store would be lost.
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

    /// After a pause in typing: it runs on the main thread.
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
