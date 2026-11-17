import Foundation

// A file's text and the operations the Files panel makes, for a file on this Mac or in a remote project (on its host).
// Paths are absolute. The project's list and search (`files.list`, `files.ignored`, `files.search`) name a workspace
// (`id`, its worktree id) and answer with paths relative to it.

/// A version of a file, where the same stamp means the same bytes. It is opaque. On this Mac it is the file's size,
/// modification time and inode (through symlinks), and on a host it is the SHA-256 of its bytes.
public typealias FileStamp = String

/// One move, from `from` to `to`.
public struct FileMove: Codable, Sendable, Equatable {
    public var from: String, to: String
    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// Returns the file's text and its stamp. It fails with an `Unopenable` error where a tab would refuse the file (a
/// pipe, past the size limit, not UTF-8), or with an error saying the file was moved or deleted.
public struct FilesRead: RPCMethod {
    public static let name = "files.read"
    public struct Result: Codable, Sendable, Equatable {
        public var text: String, stamp: FileStamp
        public init(text: String, stamp: FileStamp) {
            self.text = text
            self.stamp = stamp
        }
    }
    public var path: String
    public init(path: String) { self.path = path }
}

/// Writes `text` (UTF-8, atomically, and through a symlink to the file it points at) when the file is still at `base`,
/// the stamp it was read or last written with. With no `base`, it writes over whatever is there (Save Here, Keep Mine,
/// a new file). It answers {stamp} when written, {conflict} when not written because the file changed since (an agent's
/// edit), and {missing: true} when not written because the file is gone.
public struct FilesWrite: RPCMethod {
    public static let name = "files.write"
    public struct Conflict: Codable, Sendable, Equatable {
        /// What is in the file now. The text is nil when it isn't UTF-8.
        public var stamp: FileStamp, text: String?
        public init(stamp: FileStamp, text: String?) {
            self.stamp = stamp
            self.text = text
        }
    }
    public struct Result: Codable, Sendable, Equatable {
        public var stamp: FileStamp?, conflict: Conflict?, missing: Bool?
        public init(stamp: FileStamp? = nil, conflict: Conflict? = nil, missing: Bool? = nil) {
            self.stamp = stamp
            self.conflict = conflict
            self.missing = missing
        }
    }
    public var path: String, text: String, base: FileStamp?
    public init(path: String, text: String, base: FileStamp?) {
        self.path = path
        self.text = text
        self.base = base
    }
}

/// Moves each pair in order, stopping at the first that fails. With `unique`, a `to` that is taken becomes Finder's
/// "name copy.ext", "name copy 2.ext"… It returns the moves as they were made, and why the next one failed.
public struct FilesMove: RPCMethod {
    public static let name = "files.move"
    public struct Result: Codable, Sendable, Equatable {
        public var done: [FileMove], error: String?
        public init(done: [FileMove], error: String?) {
            self.done = done
            self.error = error
        }
    }
    public var pairs: [FileMove], unique: Bool?
    public init(pairs: [FileMove], unique: Bool? = nil) {
        self.pairs = pairs
        self.unique = unique
    }
}

/// Moves each path to the Trash, stopping at the first that fails. It returns where each went (`to`), so ⌘Z can move
/// it back.
public struct FilesTrash: RPCMethod {
    public static let name = "files.trash"
    public typealias Result = FilesMove.Result
    public var paths: [String]
    public init(paths: [String]) { self.paths = paths }
}

/// Copies each path into folder `into`, as Finder's "name copy.ext" when the name is taken. It returns the copies made,
/// and why the next one failed.
public struct FilesCopy: RPCMethod {
    public static let name = "files.copy"
    public struct Result: Codable, Sendable, Equatable {
        public var made: [String], error: String?
        public init(made: [String], error: String?) {
            self.made = made
            self.error = error
        }
    }
    public var paths: [String], into: String
    public init(paths: [String], into: String) {
        self.paths = paths
        self.into = into
    }
    /// No timeout, because copying a folder dropped from Finder takes as long as it takes.
    public static var timeout: TimeInterval? { nil }
}

/// Creates a file with `text` (empty by default), or a folder, along with the folders above it, and returns its path.
/// With `unique`, a taken name becomes the first free one of "name 2.ext", "name 3.ext"… (like Finder's "untitled 2").
/// Without it, a taken name fails.
public struct FilesCreate: RPCMethod {
    public static let name = "files.create"
    public typealias Result = String
    public var path: String, folder: Bool?, text: String?, unique: Bool?
    public init(path: String, folder: Bool? = nil, text: String? = nil, unique: Bool? = nil) {
        self.path = path
        self.folder = folder
        self.text = text
        self.unique = unique
    }
}

/// Copies a remote project's file to this Mac for a viewer that reads files (an image, a PDF, what Quick Look shows),
/// and returns the copy's path. For a file on this Mac, it returns the file's own path. It refuses files the way
/// `files.read` does (a pipe, past the size limit), whether they are text or not.
public struct FilesFetch: InternalMethod {
    public static let name = "files.fetch"
    public typealias Result = String
    public var path: String
    public init(path: String) { self.path = path }
}

/// Lists the project's files as relative paths.
public struct FilesList: RPCMethod {
    public static let name = "files.list"
    public typealias Result = [String]
    public var id: String
    public init(id: String) { self.id = id }
}
/// Lists what git ignores in the project (.build/, .env…) as relative paths. A folder ignored as a whole ends with "/"
/// and isn't opened. With `folder` (one of those folders), it lists what is in it, one level deep, with its folders
/// ending in "/".
public struct FilesIgnored: RPCMethod {
    public static let name = "files.ignored"
    public typealias Result = [String]
    public var id: String, folder: String?
    public init(id: String, folder: String? = nil) {
        self.id = id
        self.folder = folder
    }
}
/// Searches the workspace's files for `query`, as a regex if `regex` is set, matching case if `case` is set, and whole
/// words only if `word` is set.
public struct FilesSearch: RPCMethod {
    public static let name = "files.search"
    public typealias Result = [SearchMatch]
    public var id: String, query: String, regex: Bool?, `case`: Bool?, word: Bool?
    /// Set by Kelp's search box. A newer search with this flag in the same folder stops this one, because the box asks
    /// once per pause in the typing.
    public var replaces: Bool?
    public init(
        id: String, query: String, regex: Bool? = nil, case: Bool? = nil, word: Bool? = nil, replaces: Bool? = nil
    ) {
        self.id = id
        self.query = query
        self.regex = regex
        self.case = `case`
        self.word = word
        self.replaces = replaces
    }
}
