import Foundation

// `kelp artifact new|add` and an agent's hook: the daemon writes the project's `.kelp/artifacts`, so two of them
// writing a record at once can't lose one's change.

/// A new page of `kind` titled `title` in the artifacts of the workspace `cwd` is in (of chat `session`'s own when it
/// holds `cwd`; `cwd` itself in no workspace), its first lines written. Returns its file.
public struct ArtifactNew: RPCMethod {
    public static let name = "artifact.new"
    public typealias Result = String
    public var kind: Artifacts.Kind, title: String, cwd: String
    /// The chat that makes it (its KELP_SESSION): answers to a review go back there.
    public var session: String?
    public init(kind: Artifacts.Kind, title: String, cwd: String, session: String?) {
        self.kind = kind
        self.title = title
        self.cwd = cwd
        self.session = session
    }
}

/// The link to a page an agent published on its own service (`url`, https), kept in the artifacts of the workspace `cwd`
/// is in, as `artifact.new` finds it, with what its tool sent of the page (`page`, for the panel's preview). One known
/// already is a later version: it moves its time and, given them, its title and kind. Returns whether it's new.
public struct ArtifactAdd: RPCMethod {
    public static let name = "artifact.add"
    public typealias Result = Bool
    public var url: String, title: String
    /// One of `Artifacts.Kind`, or "page" for any other.
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

/// `kelp artifact check`: what Kelp's window finds wrong on a design's canvas (`path`, its canvas.json) once it has
/// drawn it again from the files: text cut off, low contrast, a board wider than its frame, a missing file. Empty:
/// nothing.
/// The window must have the canvas open (the CLI opens it first); this waits for its answer.
public struct ArtifactCheck: RPCMethod {
    public static let name = "artifact.check"
    public typealias Result = [String]
    /// How long the daemon waits for the window; the call itself a little longer.
    public static let wait: TimeInterval = 30
    public static var timeout: TimeInterval? { wait + 5 }
    public var path: String
    public init(path: String) { self.path = path }
}
