import Core
import Foundation

/// A language from `contributes.languages`: the files it covers and the language servers for them. `id` is the LSP languageId.
public struct LanguageSpec: Codable, Equatable, Sendable {
    public struct Server: Codable, Equatable, Sendable {
        public var command: String
        public var args: [String]?
        /// A shell command that installs `command`, offered when it isn't on PATH.
        public var install: String?
        /// When true, nothing is said when the server isn't installed, as for a linter or a server most people do
        /// without.
        public var optional: Bool?
        /// The server's `initializationOptions`, and its settings, which it asks for by section (`{ "gopls": { … } }`).
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

        /// Returns the server with the user's own `options` and `settings` for it (from `editor.languageServers` in
        /// settings.json, by command).
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
    /// Servers beside `server` that are each given the file too, such as linters (ruff, eslint). Problems and quick
    /// fixes come from all of them, and completion, hover and the rest from the first that has them.
    public var servers: [Server]?
    /// All the servers: `server`, then `servers`.
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

    /// The language of `path`: the last of `specs` naming its file or extension (case-insensitive). A spec whose `id`
    /// comes again later is replaced by that later one.
    public static func find(_ path: String, in specs: [LanguageSpec]) -> LanguageSpec? {
        let name = (path as NSString).lastPathComponent, ext = (name as NSString).pathExtension.lowercased()
        var seen = Set<String>()
        return specs.reversed().filter { seen.insert($0.id).inserted }
            .first { $0.fileNames?.contains(name) == true || $0.extensions.contains { $0.lowercased() == ext } }
    }
}
