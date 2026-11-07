import Core
import EditorKit
import SwiftUI

/// Settings › Editor for one language's files: settings.json's `"[markdown]": { … }` blocks, as in VS Code.
/// Which files the Editor's rows are for: all, or one language's, those with settings of their own first.
struct LanguagePicker: View {
    @Binding var language: String
    @Environment(AppModel.self) private var app

    var body: some View {
        let own = app.settings.languagesSet
        Section {
            Picker(selection: $language) {
                Text("All Files").tag("")
                Divider()
                ForEach(own, id: \.self) { Text(SettingRow.languageName($0)).tag($0) }
                if !own.isEmpty { Divider() }
                ForEach(CodeEditor.languageIds.filter { !own.contains($0) }.sorted(), id: \.self) {
                    Text(SettingRow.languageName($0)).tag($0)
                }
            } label: {
                Text("For")
                Text("A language's own value wins over the one for all files.")
            }
        }
    }
}

extension SettingRow {
    /// What an editor reads for its own language: the rest (the font, autosave, servers) is one value for every file, so the
    /// picker leaves it out. Limit: kept by hand; a setting that starts reading its language goes in here.
    static let perLanguage: Set<String> = [
        "editor.wordWrap", "editor.wordWrapColumn", "editor.rulers", "editor.renderWhitespace", "editor.tabSize",
        "editor.insertSpaces",
        "editor.detectIndentation", "editor.formatOnSave", "editor.stickyScroll", "editor.bracketColors",
        "editor.indentGuides",
        "editor.breadcrumbs"
    ]

    /// Set to something other than its default (for a language: set in its block): a dot after its title, Reset on a right-click.
    var changed: Bool {
        if let language, case .object(let block)? = store.values["[\(language)]"] { return block[spec.key] != nil }
        return language == nil && (store.values[spec.key].map { $0 != spec.default } ?? false)
    }

    func put(_ v: JSONValue?) {
        if let language { store.setOwn(spec.key, v, language: language) } else { store.set(spec.key, v) }
    }
    /// A whole number is written as one (5, not 5.0).
    func put(number v: Double) { put(v == v.rounded() ? .int(Int(v)) : .double(v)) }
    func bool() -> Bool? { store.bool(spec.key, language: language) }
    func number() -> Double? { store.number(spec.key, language: language) }
    func string() -> String? { store.string(spec.key, language: language) }

    /// A language id as people say it.
    static func languageName(_ id: String) -> String {
        [
            "plaintext": "Plain Text", "javascript": "JavaScript", "typescript": "TypeScript", "tsx": "TSX",
            "json": "JSON", "yaml": "YAML",
            "html": "HTML", "css": "CSS", "toml": "TOML", "sql": "SQL", "php": "PHP", "cpp": "C++", "c_sharp": "C#",
            "objc": "Objective-C"
        ][id]
            ?? id.prefix(1).uppercased() + id.dropFirst()
    }
}
