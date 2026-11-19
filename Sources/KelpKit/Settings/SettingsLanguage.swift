import Core
import DesignKit
import EditorKit
import SwiftUI

// Settings › Editor for one language's files, stored in settings.json as `"[markdown]": { … }` blocks, as VS Code
// does.

/// The picker that says which files the Editor's rows apply to: all files, or one language's files, with the languages
/// that have settings of their own listed first.
struct LanguagePicker: View {
    @Binding var language: String
    @Environment(AppModel.self) private var app

    var body: some View {
        let own = app.settings.languagesSet
        Section {
            Picker(selection: $language) {
                Text("All Files").tag("")
                Divider()
                ForEach(own, id: \.self) { Text(LanguageName.of($0)).tag($0) }
                if !own.isEmpty { Divider() }
                ForEach(CodeEditor.languageIds.filter { !own.contains($0) }.sorted(), id: \.self) {
                    Text(LanguageName.of($0)).tag($0)
                }
            } label: {
                // A title that says what it picks on its own, with the rule behind a ⓘ as the other rows have it.
                HStack(spacing: Metrics.gap) {
                    Text("Settings for")
                    HelpMark(text: String(localized: "A language’s own value wins over the one for all files."))
                }
            }
        }
    }
}

extension SettingRow {
    /// Whether the setting is set to something other than its default (for a language, whether its block sets it).
    /// A changed row shows a dot after its title and offers Reset on a right-click.
    var changed: Bool {
        if let language, case .object(let block)? = store.values["[\(language)]"] { return block[spec.key] != nil }
        return language == nil && (store.values[spec.key].map { $0 != spec.default } ?? false)
    }

    func put(_ value: JSONValue?) {
        if let language { store.setOwn(spec.key, value, language: language) } else { store.set(spec.key, value) }
    }
    /// Stores a number, writing a whole number as one (5, not 5.0).
    func put(number value: Double) { put(value == value.rounded() ? .int(Int(value)) : .double(value)) }
    func bool() -> Bool? { store.bool(spec.key, language: language) }
    func number() -> Double? { store.number(spec.key, language: language) }
    func string() -> String? { store.string(spec.key, language: language) }
}

/// A language id as people say it: "javascript" is JavaScript, "swift" Swift.
package enum LanguageName {
    package static func of(_ id: String) -> String {
        [
            "plaintext": "Plain Text", "javascript": "JavaScript", "typescript": "TypeScript", "tsx": "TSX",
            "json": "JSON", "yaml": "YAML",
            "html": "HTML", "css": "CSS", "toml": "TOML", "sql": "SQL", "php": "PHP", "cpp": "C++", "c_sharp": "C#",
            "objc": "Objective-C"
        ][id]
            ?? id.prefix(1).uppercased() + id.dropFirst()
    }
}
