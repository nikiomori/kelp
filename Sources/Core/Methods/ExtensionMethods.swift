import Foundation

/// Returns what the extension library (`ExtensionFiles.libraryIndex`) holds, read from its index.json. The
/// `extensions.library` setting can name another index (a team's own library, a fork being tested).
public struct ExtensionLibrary: InternalMethod {
    public static let name = "extension.library"
    public typealias Result = [Entry]
    public struct Entry: Codable, Sendable, Equatable {
        public var id: String, name: String, version: String
        public var description: String?, icon: String?
        /// Commands the extension needs on PATH. Without them, it stays inactive.
        public var requires: [String]?
        /// The category the library files the extension under: tools, themes, icons, languages, agents or
        /// integrations. nil in an index from before categories.
        public var category: String?
        /// The reviewed folder on GitHub at its reviewed commit, which is what `extension.fetch` takes.
        public var source: String
        /// Each file's SHA-256 as reviewed, keyed by path in the folder. An install takes exactly these bytes or
        /// nothing.
        public var files: [String: String]?
        /// false for an extension found on GitHub by its `kelp-extension` topic and never reviewed. Such extensions are
        /// shown apart, with a warning.
        public var reviewed: Bool?
        /// The repository's stars, and how many it gained in the last week, which the unreviewed list is sorted by.
        public var stars: Int?, weekly: Int?
        public init(
            id: String, name: String, version: String, description: String? = nil, icon: String? = nil,
            requires: [String]? = nil,
            category: String? = nil, source: String
        ) {
            self.id = id
            self.name = name
            self.version = version
            self.description = description
            self.icon = icon
            self.requires = requires
            self.category = category
            self.source = source
        }

        /// Whether every word of `query` is in the entry's id, name, description or category, ignoring case. An empty
        /// query matches all entries.
        public func matches(_ query: String) -> Bool {
            let text = [id, name, description ?? "", category ?? ""].joined(separator: " ")
            return query.split(whereSeparator: \.isWhitespace).allSatisfy { text.localizedCaseInsensitiveContains($0) }
        }
    }
    public init() {}
}

/// Downloads an extension from GitHub (`ExtensionFiles.librarySource` reads the accepted forms) into a new temporary
/// folder named after its id, with `.kelp-source.json` saying where it came from. Nothing is installed. The caller
/// shows what the extension runs, then moves it in (`ExtensionFiles.installExtension`).
public struct ExtensionFetch: InternalMethod {
    public static let name = "extension.fetch"
    public struct Result: Codable, Sendable, Equatable {
        public var folder: String
        public init(folder: String) { self.folder = folder }
    }
    public var source: String
    /// The library's SHA-256 of each file (`Entry.files`). Any other bytes are refused, and nothing is installed.
    public var files: [String: String]?
    public init(source: String, files: [String: String]? = nil) {
        self.source = source
        self.files = files
    }
}
