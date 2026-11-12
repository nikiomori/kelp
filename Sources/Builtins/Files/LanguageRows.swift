import Core
import Foundation
import WorkbenchKit

/// A row of Settings › Languages: the languages that share their servers (C, C++, Objective-C: clangd).
struct LanguageRow: Identifiable, Equatable {
    var languages: [String]
    var name: String, files: String
    var servers: [LanguageSpec.Server]
    var id: String { languages.joined(separator: ",") }
}

enum LanguageRows {
    /// The languages that have a server, those of the same servers on one row, in the order they're declared.
    static func rows(_ languages: [LanguageSpec]) -> [LanguageRow] {
        var rows: [LanguageRow] = []
        for language in languages where !language.allServers.isEmpty {
            let files = language.extensions.map { "." + $0 } + (language.fileNames ?? [])
            if let at = rows.firstIndex(where: { $0.servers.map(\.command) == language.allServers.map(\.command) }) {
                rows[at].languages.append(language.id)
                rows[at].name += ", " + name(language.id)
                rows[at].files += ", " + files.joined(separator: ", ")
            } else {
                rows.append(
                    LanguageRow(
                        languages: [language.id], name: name(language.id), files: files.joined(separator: ", "),
                        servers: language.allServers))
            }
        }
        return rows
    }

    /// What a language is called: its id as a word, or the name people write.
    static func name(_ id: String) -> String { names[id] ?? id.prefix(1).uppercased() + id.dropFirst() }
    private static let names = [
        "typescript": "TypeScript", "typescriptreact": "TSX", "javascript": "JavaScript", "javascriptreact": "JSX",
        "cpp": "C++", "objective-c": "Objective-C", "objective-cpp": "Objective-C++", "php": "PHP", "csharp": "C#",
        "shellscript": "Shell", "ocaml": "OCaml", "json": "JSON", "jsonc": "JSONC", "html": "HTML", "css": "CSS",
        "scss": "SCSS", "yaml": "YAML", "toml": "TOML"
    ]

    /// The ids of the languages a project has files of, from its files' paths.
    static func used(_ languages: [LanguageSpec], in files: [String]) -> Set<String> {
        var kinds: Set<String> = []   // one path per extension and per bare name: a project has thousands of files
        for file in files {
            let name = (file as NSString).lastPathComponent, ext = (name as NSString).pathExtension
            kinds.insert(ext.isEmpty ? name : "x." + ext)
            if !ext.isEmpty, languages.contains(where: { $0.fileNames?.contains(name) == true }) { kinds.insert(name) }
        }
        return Set(kinds.compactMap { LanguageSpec.find($0, in: languages)?.id })
    }

    /// The rows matching what's typed: a language's name, a file extension or a server's command.
    static func matching(_ rows: [LanguageRow], _ typed: String) -> [LanguageRow] {
        let typed = typed.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return rows }
        return rows.filter { row in
            ([row.name, row.files] + row.servers.map(\.command)).contains { $0.localizedCaseInsensitiveContains(typed) }
        }
    }
}
