import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import WorkbenchKit

/// The language server's actions that reach beyond the file on screen: finding where a symbol is used, renaming it,
/// and quick fixes.
@MainActor
struct LanguageServerActions {
    let app: AppModel, tab: FileTab, root: String

    private var place: (path: String, line: Int, column: Int)? {
        tab.editor?.cursor.map { (tab.path, $0.line, $0.column) }
    }

    /// Finds where the symbol at the cursor is used, and lists the places in the Files panel's results, grouped by file
    /// as the panel's results are.
    func findReferences() {
        guard let place else { return }
        let app = app, request = LSPReferences(root: root, path: place.path, line: place.line, column: place.column)
        Task {
            await tab.lspCaughtUp()
            let found = await app.call(request) ?? []
            guard !found.isEmpty else { return Banner.show(String(localized: "No references found.")) }
            FilesPanel.shown(app) { $0.show(references: found) }
        }
    }

    func rename() {
        guard let editor = tab.editor, let place else { return }
        let word = editor.wordAtCursor, app = app, root = root
        Task { @MainActor in
            guard
                let name = await prompt(
                    String(localized: "Rename Symbol"), String(localized: "Every use changes, in every file."),
                    initial: word),
                !name.isEmpty, name != word
            else { return }
            await tab.lspCaughtUp()
            guard
                let files = await app.call(
                    LSPRename(root: root, path: place.path, line: place.line, column: place.column, name: name))
            else { return }
            guard !files.isEmpty else {
                return Banner.show(String(localized: "The language server can't rename this."))
            }
            if files.count > 1 {
                guard
                    await Self.confirm(
                        String(localized: "Rename “\(word)” to “\(name)” in \(files.count) files?"), files,
                        button: String(localized: "Rename"))
                else { return }
            }
            await apply(files)
        }
    }

    func quickFix() {
        guard let editor = tab.editor, let place else { return }
        let problem = editor.problemAtCursor, app = app, path = tab.path,
            request = LSPActions(root: root, path: place.path, line: place.line, column: place.column), tab = tab
        Task { @MainActor in
            await tab.lspCaughtUp()
            let actions = await app.call(request) ?? [], menu = NSMenu()
            for action in actions {
                menu.add(action.title) {
                    Task {
                        // A fix that changes other files (the server names them, anywhere) lists those files first,
                        // as a rename does.
                        if action.files.contains(where: { $0.path != path }) {
                            guard
                                await Self.confirm(
                                    String(
                                        localized: "“\(action.title)” changes \(action.files.count) files. Apply it?"),
                                    action.files,
                                    button: String(localized: "Apply"))
                            else { return }
                        }
                        await LanguageServerActions(app: app, tab: tab, root: tab.root).apply(action.files)
                    }
                }
            }
            if let problem {
                if !actions.isEmpty { menu.addItem(.separator()) }
                menu.add(String(localized: "Fix with Agent")) {
                    FileActions(app).sendToAgent(text: "\(path):\(problem.line + 1): \(problem.message)")
                }
            }
            guard menu.numberOfItems > 0 else { return Banner.show(String(localized: "No fixes here.")) }
            editor.popUpAtCursor(menu)
        }
    }

    private static func confirm(_ question: String, _ files: [CodeFileEdit], button: String) async -> Bool {
        await DesignKit.confirm(
            question,
            detail: files.map { ($0.path as NSString).abbreviatingWithTildeInPath }.prefix(12).joined(separator: "\n"),
            action: button)
    }

    /// Applies a language server's edits. The tab's own file takes its edits in the buffer, so undo covers them. Other
    /// files are written over the version just read. When another file has unsaved edits, the whole change is held
    /// back, because half a rename is worse than none.
    func apply(_ files: [CodeFileEdit]) async {
        // A server may name a file by its real path, and the tab by the path it was given (/tmp versus /private/tmp).
        func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let own = real(tab.path), others = files.filter { real($0.path) != own }
        let edited = Set(app.workbench.editedFiles.compactMap { $0.fileURL.map { real($0.path) } })
        if let held = others.first(where: { edited.contains(real($0.path)) }) {
            return Banner.show(
                String(
                    localized: "Save \((held.path as NSString).lastPathComponent) first: the change reaches it too."),
                style: .error)
        }
        var read: [(path: String, old: String, new: String, base: FileStamp)] = []
        for fileEdit in others {
            guard let onDisk = await app.call(FilesRead(path: fileEdit.path)) else { return }
            read.append((fileEdit.path, onDisk.text, TextEdits.applied(fileEdit.edits, to: onDisk.text), onDisk.stamp))
        }
        let done: [FileBatch.Done]
        switch await FileBatch.writeAll(read, app: app) {
        case .success(let written): done = written
        case .failure(let failure):
            let back =
                failure.stuck.isEmpty
                ? "" : " " + String(localized: "Changed again, so kept as it is: \(FileBatch.names(failure.stuck)).")
            let name = (failure.path as NSString).lastPathComponent
            return Banner.show(
                String(localized: "\(name) changed since it was read: nothing was changed.") + back, style: .error)
        }
        if let mine = files.first(where: { real($0.path) == own }) {
            tab.editor?.perform(mine.edits)
        }
        guard !done.isEmpty else { return }
        let app = app
        Banner.show(
            String(localized: "Changed \(done.count) other files."),
            action: (
                String(localized: "Undo"),
                {
                    Task { await FileBatch.undoSaying(done, app: app) }
                }
            ))
    }
}
