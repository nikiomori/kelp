import Foundation

/// The extension library (`ExtensionFiles.libraryIndex`): what it holds, from its index.json. Settings' `extensions.library` names
/// another index (a team's own library, a fork being tested).
public struct ExtensionLibrary: InternalMethod {
    public static let name = "extension.library"
    public typealias Result = [Entry]
    public struct Entry: Codable, Sendable, Equatable {
        public var id: String, name: String, version: String
        public var description: String?, icon: String?
        /// Commands it needs on PATH (an extension without them stays inactive).
        public var requires: [String]?
        /// What the library files it under: tools, themes, icons, languages, agents or integrations. nil: an index
        /// from before categories.
        public var category: String?
        /// The reviewed folder on GitHub, at its commit: what `extension.fetch` takes.
        public var source: String
        /// Each file's SHA-256 as reviewed, by path in the folder: an install takes these bytes or nothing.
        public var files: [String: String]?
        /// false: found on GitHub by its `kelp-extension` topic, never reviewed; shown apart, with a warning.
        public var reviewed: Bool?
        /// Its repository's stars, and how many it gained in the last week (what the unreviewed list is sorted by).
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

        /// Every word of `query` is in its id, name, description or category, any case; an empty query matches all.
        public func matches(_ query: String) -> Bool {
            let text = [id, name, description ?? "", category ?? ""].joined(separator: " ")
            return query.split(whereSeparator: \.isWhitespace).allSatisfy { text.localizedCaseInsensitiveContains($0) }
        }
    }
    public init() {}
}

/// Downloads an extension from GitHub (`ExtensionFiles.librarySource` reads the forms) into a new temporary folder named by its
/// id, with `.kelp-source.json` saying where it came from. Nothing is installed: the caller shows what it runs, then
/// moves it in (`ExtensionFiles.installExtension`).
public struct ExtensionFetch: InternalMethod {
    public static let name = "extension.fetch"
    public struct Result: Codable, Sendable, Equatable {
        public var folder: String
        public init(folder: String) { self.folder = folder }
    }
    public var source: String
    /// The library's SHA-256 of each file (`Entry.files`): other bytes are refused, nothing installed.
    public var files: [String: String]?
    public init(source: String, files: [String: String]? = nil) {
        self.source = source
        self.files = files
    }
}
