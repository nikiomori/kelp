import AppKit
import Core
import EditorKit
import WorkbenchKit
import KelpKit

/// "untitled:<n>": a new file with no name yet, like VS Code's Untitled-1. Plain text until it's saved: the first ⌘S
/// asks where and under what name (the extension makes it code; none makes it .txt), then the tab is that file's.
@MainActor @Observable
final class UntitledTab: SavableTab {
    let uri: String, app: AppModel
    let editor = CodeEditor(text: "", url: URL(fileURLWithPath: "/Untitled.txt"))
    /// The editor's keys before the menu's (⌘D), as in a file's tab.
    let view: NSView = EditorBox()
    let title: String
    var icon: NSImage? { .symbol("doc") }
    /// Any text, until Don't Save.
    private(set) var isEdited = false
    private var discarded = false
    func discard() { discarded = true; isEdited = false }

    init(uri: String, app: AppModel) {
        self.uri = uri; self.app = app
        title = String(localized: "Untitled-\(TabURI.body(uri))")
        editor.view.clipsToBounds = true
        let bar = EditorStatusBar(url: URL(fileURLWithPath: "Untitled.txt"), text: "")
        bar.show(cursor: editor.cursor)
        view.pin(stacked(editor.view, bar))
        editor.onSelection = { [weak bar, weak editor] in bar?.show(cursor: editor?.cursor) }
        editor.onChange = { [weak self] text in
            guard let self, !discarded, isEdited == text.isEmpty else { return }
            isEdited = !text.isEmpty
        }
        track(owner: self) { app.themes.editorRevision } changed: { [weak self] _ in self?.editor.refreshAppearance() }
    }

    /// The next free number in this workspace: Untitled-1, Untitled-2…
    static func next(_ app: AppModel) -> String {
        let open = Set(app.workbench.editor?.layout.allTabs.map(\.uri) ?? [])
        return (1...).lazy.map { "untitled:\($0)" }.first { !open.contains($0) } ?? "untitled:1"
    }

    func focus() { editor.focus() }

    func close() async -> Bool {
        guard isEdited else { return true }
        let a = NSAlert(); a.messageText = String(localized: "Do you want to save “\(title)”?")
        a.informativeText = String(localized: "It hasn't been saved yet, so its text will be lost if you don't save it.")
        a.addButton(withTitle: String(localized: "Save…"))
        a.addButton(withTitle: String(localized: "Cancel"))
        a.addButton(withTitle: String(localized: "Don't Save"))
        switch await runSheet(a) {
        case .alertFirstButtonReturn: return await save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    /// Asks for a name in the workspace's folder, writes the file and puts it in this tab's place.
    @discardableResult
    func save() async -> Bool {
        let p = NSSavePanel()
        p.nameFieldStringValue = Self.suggestedName(editor.text) ?? title
        p.directoryURL = app.worktree(app.workbench.workspaceId).map { URL(fileURLWithPath: $0.path) }
        p.canCreateDirectories = true; p.isExtensionHidden = false
        p.message = String(localized: "Name it with an extension for code (main.py, App.swift); without one it's a .txt file.")
        guard await runSheet(p) == .OK, var url = p.url else { return false }
        if url.pathExtension.isEmpty { url.appendPathExtension("txt") }
        // Over whatever is there: the save panel asked about replacing it.
        let res = await app.tryCall(FilesWrite(path: url.path, text: editor.text, base: nil))
        if let error = res.error { Banner.show(String(localized: "Couldn't save \(url.lastPathComponent): \(error)")); return false }
        app.workbench.editor?.replace(uri, with: TabURI.file(url.path))
        return true
    }

    /// The first line, as VS Code proposes it: "def main():" → "def main()".
    static func suggestedName(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let name = line.components(separatedBy: CharacterSet(charactersIn: "/:\\\"*?<>|")).joined().trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : String(name.prefix(40)).trimmingCharacters(in: .whitespaces)
    }
}
