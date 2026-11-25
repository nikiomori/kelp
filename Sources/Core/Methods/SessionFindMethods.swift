import Foundation

/// Finds `query` in what each of the running sessions `ids` printed lately (the last megabyte the daemon keeps), for
/// ⌘P. It matches as the terminal's own find does, ignoring the case of ASCII letters. Sessions without it, or not
/// running, are left out.
public struct SessionFind: InternalMethod {
    public static let name = "session.find"
    public typealias Result = [SessionFound]
    public var ids: [String], query: String
    public init(ids: [String], query: String) {
        self.ids = ids
        self.query = query
    }
}
/// A session's lines with what was looked for: the newest one, cut to the part around it, and how many there are.
public struct SessionFound: Codable, Sendable, Equatable {
    public var id: String, line: String, count: Int
    public init(id: String, line: String, count: Int) {
        self.id = id
        self.line = line
        self.count = count
    }
}
