import AppKit
import Core
import EditorKit
import KelpKit
import WorkbenchKit

/// What a language server does beyond the file on screen: where a symbol is used, renaming it, its fixes.
@MainActor
struct ServerActions {
    let app: AppModel, tab: FileTab, root: String

    private var place: (path: String, line: Int, column: Int)? { tab.editor?.cursor.map { (tab.path, $0.line, $0.column) } }

    /// In the Files panel's results, grouped by file as those are.
    func findReferences() {
        guard let p = place else { return }
        let app = app, m = LSPReferences(root: root, path: p.path, line: p.line, column: p.column)
        Task {
            let found = await app.call(m) ?? []
            guard !found.isEmpty else { return Banner.show(String(localized: "No references found.")) }
            app.workbench.showPanel("files")
            DispatchQueue.main.async { (app.workbench.builtPanel("files") as? FilesPanel)?.show(references: found) }   // after the panel is built
        }
    }

    func rename() {
        guard let e = tab.editor, let p = place else { return }
        let word = e.wordAtCursor, app = app, root = root
        Task { @MainActor in
            guard let name = await prompt(String(localized: "Rename Symbol"), String(localized: "Every use changes, in every file."), initial: word),
                  !name.isEmpty, name != word else { return }
            guard let files = await app.call(LSPRename(root: root, path: p.path, line: p.line, column: p.column, name: name)) else { return }
            guard !files.isEmpty else { return Banner.show(String(localized: "The language server can't rename this.")) }
            if files.count > 1 {
                guard await Self.confirm(String(localized: "Rename “\(word)” to “\(name)” in \(files.count) files?"), files,
                                         button: String(localized: "Rename")) else { return }
            }
            await apply(files)
        }
    }

    func quickFix() {
        guard let e = tab.editor, let p = place else { return }
        let problem = e.problemAtCursor, app = app, path = tab.path, m = LSPActions(root: root, path: p.path, line: p.line, column: p.column), tab = tab
        Task { @MainActor in
            let actions = await app.call(m) ?? [], menu = NSMenu()
            for a in actions {
                menu.add(a.title) {
                    Task {
                        // A fix that reaches other files (the server names them, anywhere) shows which first, as a rename does.
                        if a.files.contains(where: { $0.path != path }) {
                            guard await Self.confirm(String(localized: "“\(a.title)” changes \(a.files.count) files. Apply it?"), a.files,
                                                     button: String(localized: "Apply")) else { return }
                        }
                        await ServerActions(app: app, tab: tab, root: tab.root).apply(a.files)
                    }
                }
            }
            if let problem {
                if !actions.isEmpty { menu.addItem(.separator()) }
                menu.add(String(localized: "Fix with Agent")) { FileActions(app).sendToAgent(text: "\(path):\(problem.line + 1): \(problem.message)") }
            }
            guard menu.numberOfItems > 0 else { return Banner.show(String(localized: "No fixes here.")) }
            e.popUpAtCursor(menu)
        }
    }

    private static func confirm(_ question: String, _ files: [CodeFileEdit], button: String) async -> Bool {
        let a = NSAlert()
        a.messageText = question
        a.informativeText = files.map { ($0.path as NSString).abbreviatingWithTildeInPath }.prefix(12).joined(separator: "\n")
        a.addButton(withTitle: button)
        a.addButton(withTitle: String(localized: "Cancel"))
        return await runSheet(a) == .alertFirstButtonReturn
    }

    /// The tab's own file takes the edits in its buffer, for its undo. Others are written, over the version just read; a file
    /// with unsaved edits holds the whole change back, half a rename being worse than none.
    func apply(_ files: [CodeFileEdit]) async {
        // A server may name it by its real path, the tab by the one it was given (/tmp, /private/tmp).
        func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let own = real(tab.path), others = files.filter { real($0.path) != own }
        let edited = Set(app.workbench.editedFiles.compactMap { $0.fileURL.map { real($0.path) } })
        if let held = others.first(where: { edited.contains(real($0.path)) }) {
            return Banner.show(String(localized: "Save \((held.path as NSString).lastPathComponent) first: the change reaches it too."), style: .error)
        }
        var read: [(path: String, old: String, new: String, base: FileStamp)] = []
        for f in others {
            guard let r = await app.call(FilesRead(path: f.path)) else { return }
            read.append((f.path, r.text, TextEdits.applied(f.edits, to: r.text), r.stamp))
        }
        let done: [FileBatch.Done]
        switch await FileBatch.writeAll(read, app: app) {
        case .success(let d): done = d
        case .failure(let r):
            let back = r.stuck.isEmpty ? "" : " " + String(localized: "Changed again, so kept as it is: \(FileBatch.names(r.stuck)).")
            let name = (r.path as NSString).lastPathComponent
            return Banner.show(String(localized: "\(name) changed since it was read: nothing was changed.") + back, style: .error)
        }
        if let mine = files.first(where: { real($0.path) == own }) {
            tab.editor?.perform(mine.edits.map { .init(line: $0.line, column: $0.column, endLine: $0.endLine, endColumn: $0.endColumn, text: $0.text) })
        }
        guard !done.isEmpty else { return }
        let app = app
        Banner.show(String(localized: "Changed \(done.count) other files."), action: (String(localized: "Undo"), {
            Task { await FileBatch.undoSaying(done, app: app) }
        }))
    }
}
