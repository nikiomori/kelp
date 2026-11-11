import Core
import Foundation

/// A language from `contributes.languages`: the files it covers and the language servers for them. `id` is the LSP languageId.
public struct LanguageSpec: Codable, Equatable, Sendable {
    public struct Server: Codable, Equatable, Sendable {
        public var command: String
        public var args: [String]?
        /// A shell command that installs `command`, offered when it isn't on PATH.
        public var install: String?
        /// Nothing is said when it isn't installed: a linter, or a server most people do without.
        public var optional: Bool?
        /// Its `initializationOptions`, and its settings (what it asks for by section: `{ "gopls": { … } }`).
        public var options: JSONValue?, settings: JSONValue?

        public init(
            command: String, args: [String]? = nil, install: String? = nil, optional: Bool? = nil,
            options: JSONValue? = nil, settings: JSONValue? = nil
        ) {
            self.command = command
            self.args = args
            self.install = install
            self.optional = optional
            self.options = options
            self.settings = settings
        }

        /// With the user's own `options` and `settings` for it (settings.json's `editor.languageServers`, by command).
        public func with(_ own: JSONValue?) -> Server {
            var server = self
            server.options = own?["options"] ?? options
            server.settings = own?["settings"] ?? settings
            return server
        }
    }
    public var id: String
    public var extensions: [String]
    /// Whole file names, e.g. "Dockerfile".
    public var fileNames: [String]?
    public var server: Server?
    /// Servers beside `server`, each given the file too: linters (ruff, eslint). Problems and quick fixes come from
    /// all; completion, hover and the rest from the first that has them.
    public var servers: [Server]?
    /// `server`, then `servers`.
    public var allServers: [Server] { (server.map { [$0] } ?? []) + (servers ?? []) }
    /// Shell commands for Run File, Test at Cursor and Format Document (`format` reads the text on stdin, prints it formatted).
    public var run: String?, test: String?, format: String?

    public init(
        id: String, extensions: [String], fileNames: [String]? = nil, server: Server? = nil,
        servers: [Server]? = nil, run: String? = nil, test: String? = nil, format: String? = nil
    ) {
        self.id = id
        self.extensions = extensions
        self.fileNames = fileNames
        self.server = server
        self.servers = servers
        self.run = run
        self.test = test
        self.format = format
    }

    /// `run`, `test` or `format` by name.
    public subscript(command name: String) -> String? { ["run": run, "test": test, "format": format][name] ?? nil }

    /// The word (letters, digits, `_`) at a 1-based line and UTF-16 column: `${symbol}` when no language server names one.
    public static func word(in text: String, line: Int, column: Int) -> String {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)   // CRLF files too
        guard lines.indices.contains(line - 1) else { return "" }
        let lineText = lines[line - 1],
            at = lineText.utf16.index(lineText.startIndex, offsetBy: min(max(column - 1, 0), lineText.utf16.count))
        let isWord = { (character: Character) in character.isLetter || character.isNumber || character == "_" }
        return String(lineText[..<at].reversed().prefix(while: isWord).reversed())
            + lineText[at...].prefix(while: isWord)
    }

    /// The language of `path`: the last of `specs` naming its file or extension (case-insensitive). A spec whose `id`
    /// comes again later is replaced by that later one.
    public static func find(_ path: String, in specs: [LanguageSpec]) -> LanguageSpec? {
        let name = (path as NSString).lastPathComponent, ext = (name as NSString).pathExtension.lowercased()
        var seen = Set<String>()
        return specs.reversed().filter { seen.insert($0.id).inserted }
            .first { $0.fileNames?.contains(name) == true || $0.extensions.contains { $0.lowercased() == ext } }
    }
}
