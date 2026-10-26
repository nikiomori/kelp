import Foundation

// A file's text and the operations the Files panel makes, for a file on this Mac or in a remote project (on its host).
// Paths are absolute.

/// A version of a file: the same stamp, the same bytes. Opaque: its size, modification time and inode here (through
/// symlinks), the SHA-256 of its bytes on a host.
public typealias FileStamp = String

/// One move: `from` → `to`.
public struct FileMove: Codable, Sendable, Equatable {
    public var from: String, to: String
    public init(from: String, to: String) { self.from = from; self.to = to }
}

/// The file's text and its stamp. Fails with an `Unopenable` error where a tab would refuse it (a pipe, past the size
/// limit, not UTF-8), or saying it was moved or deleted.
public struct FilesRead: RPCMethod {
    public static let name = "files.read"
    public struct Result: Codable, Sendable, Equatable {
        public var text: String, stamp: FileStamp
        public init(text: String, stamp: FileStamp) { self.text = text; self.stamp = stamp }
    }
    public var path: String
    public init(path: String) { self.path = path }
}

/// Writes `text` (UTF-8, atomically, through a symlink to the file it points at) when the file is still `base`, the
/// stamp it was read or last written as; with no `base`, whatever is there (Save Here, Keep Mine, a new file).
/// → {stamp}: written. → {conflict}: unwritten, it changed since (an agent's edit). → {missing: true}: unwritten, it's gone.
public struct FilesWrite: RPCMethod {
    public static let name = "files.write"
    public struct Conflict: Codable, Sendable, Equatable {
        /// What's there now; its text nil when that isn't UTF-8.
        public var stamp: FileStamp, text: String?
        public init(stamp: FileStamp, text: String?) { self.stamp = stamp; self.text = text }
    }
    public struct Result: Codable, Sendable, Equatable {
        public var stamp: FileStamp?, conflict: Conflict?, missing: Bool?
        public init(stamp: FileStamp? = nil, conflict: Conflict? = nil, missing: Bool? = nil) {
            self.stamp = stamp; self.conflict = conflict; self.missing = missing
        }
    }
    public var path: String, text: String, base: FileStamp?
    public init(path: String, text: String, base: FileStamp?) { self.path = path; self.text = text; self.base = base }
}

/// Moves each pair in order, stopping at the first that fails. `unique`: a `to` that's taken becomes Finder's
/// "name copy.ext", "name copy 2.ext"… → the moves made (as made), and why the next one failed.
public struct FilesMove: RPCMethod {
    public static let name = "files.move"
    public struct Result: Codable, Sendable, Equatable {
        public var done: [FileMove], error: String?
        public init(done: [FileMove], error: String?) { self.done = done; self.error = error }
    }
    public var pairs: [FileMove], unique: Bool?
    public init(pairs: [FileMove], unique: Bool? = nil) { self.pairs = pairs; self.unique = unique }
}

/// Moves each path to the Trash, stopping at the first that fails → where each went (`to`, for ⌘Z to move it back).
public struct FilesTrash: RPCMethod {
    public static let name = "files.trash"; public typealias Result = FilesMove.Result
    public var paths: [String]
    public init(paths: [String]) { self.paths = paths }
}

/// Copies each path into folder `into`, as Finder's "name copy.ext" when the name is taken → the copies made, and why
/// the next one failed.
public struct FilesCopy: RPCMethod {
    public static let name = "files.copy"
    public struct Result: Codable, Sendable, Equatable {
        public var made: [String], error: String?
        public init(made: [String], error: String?) { self.made = made; self.error = error }
    }
    public var paths: [String], into: String
    public init(paths: [String], into: String) { self.paths = paths; self.into = into }
    /// Copying a folder dropped from Finder takes as long as it takes.
    public static var timeout: TimeInterval? { nil }
}

/// A file with `text` (empty by default), or a folder, with the folders above it → its path. `unique`: when the name is
/// taken, the first free one of "name 2.ext", "name 3.ext"… (Finder's "untitled 2"); otherwise a taken name fails.
public struct FilesCreate: RPCMethod {
    public static let name = "files.create"; public typealias Result = String
    public var path: String, folder: Bool?, text: String?, unique: Bool?
    public init(path: String, folder: Bool? = nil, text: String? = nil, unique: Bool? = nil) {
        self.path = path; self.folder = folder; self.text = text; self.unique = unique
    }
}

/// A remote project's file copied to this Mac for a viewer that reads a file (an image, a PDF, what Quick Look shows) →
/// the copy's path; a file here → its own path. Refused like `files.read` (a pipe, past the size limit), text or not.
public struct FilesFetch: RPCMethod {
    public static let name = "files.fetch"; public typealias Result = String; public var path: String
    public init(path: String) { self.path = path }
}
