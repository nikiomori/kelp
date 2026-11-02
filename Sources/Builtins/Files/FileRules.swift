import AppKit
import Core
import EditorKit
import KelpKit
import WorkbenchKit

/// How one file is indented and what Save tidies. A choice made in the status bar comes first, then the project's
/// `.editorconfig`, then what the file itself does, then the settings for its language.
@MainActor
final class FileRules {
    private let app: AppModel, path: String, root: String
    private weak var editor: CodeEditor?, bar: EditorStatusBar?
    private var config = EditorRules()
    private var chosen: (tabSize: Int?, spaces: Bool?) = (nil, nil)
    private let detected: Indentation?

    init(app: AppModel, path: String, root: String, editor: CodeEditor, bar: EditorStatusBar) {
        self.app = app
        self.path = path
        self.root = root
        self.editor = editor
        self.bar = bar
        let language = editor.languageId
        detected = app.settings.bool("editor.detectIndentation", language: language) != false ? Indentation.detect(editor.text) : nil
        bar.indentMenu = { [weak self] in self?.menu() ?? NSMenu() }
        track(owner: self) { [settings = app.settings] in
            [settings.number("editor.tabSize", language: language), settings.bool("editor.insertSpaces", language: language) == false ? 1 : 0]
        } changed: { [weak self] _ in self?.apply() }
        Task { [weak self] in await self?.readConfig() }
    }

    private var tabSize: Int {
        let language = editor?.languageId
        var fromFile: Int?
        if case .spaces(let n)? = detected { fromFile = n }
        return chosen.tabSize ?? config.tabSize ?? fromFile ?? Int(app.settings.number("editor.tabSize", language: language) ?? 4)
    }

    private var spaces: Bool {
        var fromFile: Bool?
        if let detected { fromFile = detected != .tabs }
        return chosen.spaces ?? config.insertSpaces ?? fromFile ?? (app.settings.bool("editor.insertSpaces", language: editor?.languageId) != false)
    }

    private func apply() {
        let size = max(tabSize, 1), spaces = spaces
        editor?.useIndent(tabWidth: size, spaces: spaces)
        bar?.show(indent: spaces ? .spaces(size) : .tabs)
    }

    /// From the file's folder up to the workspace's, or a `root = true`: the nearer one's say stands.
    private func readConfig() async {
        var folder = (path as NSString).deletingLastPathComponent, found = EditorRules()
        while folder.hasPrefix(root) {
            if let text = await app.quiet(FilesRead(path: folder + "/.editorconfig"))?.text {
                let (rules, isRoot) = EditorConfig.read(text, file: String(path.dropFirst(folder.count + 1)))
                found = found.over(rules)
                if isRoot { break }
            }
            guard folder != root else { break }
            folder = (folder as NSString).deletingLastPathComponent
        }
        config = found
        apply()
    }

    /// ⌘S's tidying, one step of undo with what was typed before it. Autosave leaves the line being typed alone.
    func cleanUpForSave() {
        guard let e = editor else { return }
        let language = e.languageId
        let trim = config.trimTrailingWhitespace ?? app.settings.bool("files.trimTrailingWhitespace", language: language) == true
        let final = config.insertFinalNewline ?? app.settings.bool("files.insertFinalNewline", language: language) == true
        guard trim || final else { return }
        let text = e.text, clean = Indentation.cleaned(text, trim: trim, finalNewline: final)
        if clean != text { e.apply(text: clean, selection: e.selectedRange) }
    }

    private func menu() -> NSMenu {
        let m = NSMenu(), spaces = spaces, size = max(tabSize, 1)
        m.add(String(localized: "Indent Using Spaces")) { [weak self] in self?.choose(spaces: true) }.state = spaces ? .on : .off
        m.add(String(localized: "Indent Using Tabs")) { [weak self] in self?.choose(spaces: false) }.state = spaces ? .off : .on
        m.addItem(.separator())
        for n in [2, 4, 8] {
            m.add(String(localized: "Width: \(n)")) { [weak self] in self?.choose(tabSize: n) }.state = size == n ? .on : .off
        }
        m.addItem(.separator())
        m.add(String(localized: "Convert File to Spaces")) { [weak self] in self?.convert(.spaces(size)) }
        m.add(String(localized: "Convert File to Tabs")) { [weak self] in self?.convert(.tabs) }
        return m
    }

    private func choose(tabSize: Int? = nil, spaces: Bool? = nil) {
        chosen = (tabSize ?? chosen.tabSize, spaces ?? chosen.spaces)
        apply()
    }

    private func convert(_ to: Indentation) {
        guard let e = editor else { return }
        let size = max(tabSize, 1), text = e.text, new = to.applied(to: text, tabSize: size)
        if new != text { e.apply(text: new, selection: NSRange(location: 0, length: 0)) }
        choose(spaces: to != .tabs)
    }
}
