import AppKit

/// A file icon theme in VS Code's format (what `contributes.iconThemes` points at): icon definitions, then associations
/// by file name, extension, language and folder name, with an optional `light` section. Icons given by `iconPath`
/// (SVG, PNG) are drawn; font glyphs (`fontCharacter`, as in Seti) aren't, and those files keep the system icon.
@MainActor
final class IconTheme {
    private struct Associations: Decodable {
        var file: String?, folder: String?, folderExpanded: String?
        var fileExtensions: [String: String]?, fileNames: [String: String]?, languageIds: [String: String]?
        var folderNames: [String: String]?, folderNamesExpanded: [String: String]?

        /// Names match case-insensitively, as in VS Code.
        func lowercased() -> Associations {
            func l(_ d: [String: String]?) -> [String: String]? {
                d.map { Dictionary($0.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a }) }
            }
            return Associations(
                file: file, folder: folder, folderExpanded: folderExpanded, fileExtensions: l(fileExtensions),
                fileNames: l(fileNames),
                languageIds: languageIds, folderNames: l(folderNames), folderNamesExpanded: l(folderNamesExpanded))
        }
    }
    private struct Document: Decodable {
        struct Definition: Decodable { var iconPath: String? }
        var iconDefinitions: [String: Definition]
        var base: Associations, light: Associations?
        private enum Keys: String, CodingKey { case iconDefinitions, light }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: Keys.self)
            iconDefinitions = try c.decode([String: Definition].self, forKey: .iconDefinitions)
            light = try c.decodeIfPresent(Associations.self, forKey: .light)
            base = try Associations(from: d)
        }
    }

    private let paths: [String: String]   // definition id → icon file
    private let base: Associations, light: Associations?
    private var pictures: [String: NSImage?] = [:]
    private var pairs: [String: NSImage] = [:]

    init(contentsOf url: URL) throws {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true   // VS Code themes may have comments
        let doc = try decoder.decode(Document.self, from: Data(contentsOf: url))
        let dir = url.deletingLastPathComponent()
        paths = doc.iconDefinitions.compactMapValues {
            $0.iconPath.map { dir.appendingPathComponent($0).standardizedFileURL.path }
        }
        base = doc.base.lowercased()
        light = doc.light?.lowercased()
    }

    /// nil when the theme has no picture for it.
    func image(_ name: String, folder: Bool, expanded: Bool) -> NSImage? {
        let n = name.lowercased()
        let dark = definition(n, folder, expanded, [base]).flatMap(picture)
        guard let light, let lite = definition(n, folder, expanded, [light, base]).flatMap(picture), lite !== dark
        else { return dark }
        guard let dark else { return lite }
        let key = "\(ObjectIdentifier(dark).hashValue)/\(ObjectIdentifier(lite).hashValue)"
        if let p = pairs[key] { return p }
        let p = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
            (NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : lite).draw(in: r)
            return true
        }
        pairs[key] = p
        return p
    }

    /// VS Code's order: file name, then extensions longest first ("d.ts" before "ts"), language, the default file icon.
    private func definition(_ n: String, _ folder: Bool, _ expanded: Bool, _ sections: [Associations]) -> String? {
        func first(_ pick: (Associations) -> String?) -> String? { sections.lazy.compactMap(pick).first }
        if folder {
            if expanded, let id = first({ $0.folderNamesExpanded?[n] }) { return id }
            return first { $0.folderNames?[n] } ?? (expanded ? first { $0.folderExpanded } : nil) ?? first { $0.folder }
        }
        if let id = first({ $0.fileNames?[n] }) { return id }
        var rest = Substring(n)
        while let dot = rest.firstIndex(of: ".") {
            rest = rest[rest.index(after: dot)...]
            if let id = first({ $0.fileExtensions?[String(rest)] }) { return id }
        }
        if let lang = Self.languageByName[n] ?? Self.language[(n as NSString).pathExtension],
            let id = first({ $0.languageIds?[lang] })
        {
            return id
        }
        return first { $0.file }
    }

    private func picture(_ id: String) -> NSImage? {
        guard let path = paths[id] else { return nil }
        if let p = pictures[path] { return p }
        let img = NSImage(contentsOfFile: path)
        img?.size = NSSize(width: 16, height: 16)
        pictures[path] = img
        return img
    }

    /// VS Code language ids, which themes use for most languages (`"languageIds": {"swift": …}`).
    private static let language: [String: String] = [
        "swift": "swift", "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascriptreact",
        "ts": "typescript", "mts": "typescript", "cts": "typescript", "tsx": "typescriptreact",
        "py": "python", "pyi": "python", "go": "go", "rs": "rust", "rb": "ruby", "java": "java", "kt": "kotlin",
        "kts": "kotlin",
        "c": "c", "h": "cpp", "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp", "m": "objective-c",
        "mm": "objective-cpp",
        "cs": "csharp", "fs": "fsharp", "php": "php", "lua": "lua", "dart": "dart", "r": "r", "pl": "perl",
        "groovy": "groovy",
        "html": "html", "htm": "html", "css": "css", "scss": "scss", "less": "less", "json": "json", "jsonc": "jsonc",
        "jsonl": "jsonl",
        "yaml": "yaml", "yml": "yaml", "toml": "toml", "xml": "xml", "md": "markdown", "markdown": "markdown",
        "sh": "shellscript", "bash": "shellscript", "zsh": "shellscript", "ps1": "powershell", "bat": "bat",
        "cmd": "bat",
        "sql": "sql", "txt": "plaintext", "ini": "ini", "properties": "properties", "diff": "diff", "patch": "diff",
        "graphql": "graphql", "gql": "graphql", "zig": "zig", "nix": "nix", "jl": "julia", "clj": "clojure",
        "coffee": "coffeescript",
        "tex": "latex", "vue": "vue", "svelte": "svelte", "mmd": "mermaid", "dockerfile": "dockerfile"
    ]
    private static let languageByName: [String: String] = [
        "dockerfile": "dockerfile", "containerfile": "dockerfile", "makefile": "makefile", "gnumakefile": "makefile",
        ".gitignore": "ignore", ".npmignore": "ignore", ".dockerignore": "ignore", ".env": "dotenv",
        ".editorconfig": "editorconfig",
        "compose.yml": "dockercompose", "compose.yaml": "dockercompose", "docker-compose.yml": "dockercompose",
        "docker-compose.yaml": "dockercompose"
    ]
}
