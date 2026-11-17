import Foundation

// The methods behind `kelp artifact new|add` and an agent's hook. The daemon writes the project's `.kelp/artifacts`
// itself, so two callers writing a record at once can't lose each other's change.

/// Makes a new page of `kind` titled `title`, with its first lines written, and returns its file. The page goes in the
/// artifacts of the workspace that holds `cwd`, preferring the workspace of chat `session` when it holds `cwd`. When no
/// workspace holds `cwd`, the page goes under `cwd` itself.
public struct ArtifactNew: RPCMethod {
    public static let name = "artifact.new"
    public typealias Result = String
    public var kind: Artifacts.Kind, title: String, cwd: String
    /// The chat that makes the page (its KELP_SESSION), where answers to a review go back.
    public var session: String?
    public init(kind: Artifacts.Kind, title: String, cwd: String, session: String?) {
        self.kind = kind
        self.title = title
        self.cwd = cwd
        self.session = session
    }
}

/// Keeps the link to a page an agent published on its own service (`url`, https) in the artifacts of the workspace that
/// holds `cwd`, found the way `artifact.new` finds it. It also keeps what the tool sent of the page (`page`, for the
/// panel's preview). A link already known is a later version, so it updates the time and, when given, the title and
/// kind. Returns whether the link is new.
public struct ArtifactAdd: RPCMethod {
    public static let name = "artifact.add"
    public typealias Result = Bool
    public var url: String, title: String
    /// One of `Artifacts.Kind`, or "page" for any other kind.
    public var type: String
    public var cwd: String, session: String?, page: PublishedPage?
    public init(url: String, title: String, type: String, cwd: String, session: String?, page: PublishedPage? = nil) {
        self.url = url
        self.title = title
        self.type = type
        self.cwd = cwd
        self.session = session
        self.page = page
    }
}

/// `kelp artifact check` returns what Kelp's window finds wrong on a design's canvas (`path`, its canvas.json) once it
/// has drawn the canvas again from the files: text cut off, low contrast, a board wider than its frame, a missing file.
/// Empty when nothing is wrong.
/// The window must have the canvas open (the CLI opens it first), and this call waits for the window's answer.
public struct ArtifactCheck: RPCMethod {
    public static let name = "artifact.check"
    public typealias Result = [String]
    /// How long the daemon waits for the window. The call itself waits a little longer.
    public static let wait: TimeInterval = 30
    public static var timeout: TimeInterval? { wait + 5 }
    public var path: String
    public init(path: String) { self.path = path }
}

/// Returns what the chat that made a page spent on it: its model calls from the page's start to its last change, priced
/// as the API would price them. It works only for Claude Code's chats, whose transcripts are on this Mac. nil for
/// another agent's chat, or when none is found.
public struct ArtifactCost: InternalMethod {
    public static let name = "artifact.cost"
    public struct Spent: Codable, Sendable, Equatable {
        /// The number of model calls, the tokens written, the tokens read (the prompt, including its cached part),
        /// and the cost in US dollars.
        public var calls: Int, output: Int, read: Int, cost: Double
        public init(calls: Int, output: Int, read: Int, cost: Double) {
            self.calls = calls
            self.output = output
            self.read = read
            self.cost = cost
        }
    }
    public typealias Result = Spent?
    /// The page's file.
    public var path: String
    public init(path: String) { self.path = path }
}
