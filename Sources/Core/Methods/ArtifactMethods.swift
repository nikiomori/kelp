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
    /// The page's id on the service (`ArtifactRecord.serviceId`).
    public var serviceId: String?
    public init(
        url: String, title: String, type: String, cwd: String, session: String?, page: PublishedPage? = nil,
        serviceId: String? = nil
    ) {
        self.url = url
        self.title = title
        self.type = type
        self.cwd = cwd
        self.session = session
        self.page = page
        self.serviceId = serviceId
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

/// Changes the marks on a page (`path`, its file) as the window asks: its drafts, a send, done, again, a hand edit.
/// The daemon applies the change to `notes.json` as it is then. A send first keeps a version of the page as the user
/// sends it, when it changed since the last one, so the marks are checked against what the user saw; `pictures`
/// holds the PNG of each area or stroke being sent, by mark number. Returns the marks as written.
public struct ArtifactMarksChange: InternalMethod {
    public static let name = "artifact.marks"
    public typealias Result = ArtifactMarks
    public var path: String, change: ArtifactMarks.Change
    public var pictures: [String: Data]?
    public init(path: String, change: ArtifactMarks.Change, pictures: [String: Data]? = nil) {
        self.path = path
        self.change = change
        self.pictures = pictures
    }
}

/// Keeps a version of a page (`path`, its file) as the user's hand edits left it, labelled with what they changed.
/// Nothing is kept when the page is the same as its last version. Returns whether a version was kept.
public struct ArtifactKeepVersion: InternalMethod {
    public static let name = "artifact.keepVersion"
    public typealias Result = Bool
    public var path: String, label: String
    public init(path: String, label: String) {
        self.path = path
        self.label = label
    }
}

/// Keeps the page (`path`, its file) as a new version once the user brought version `from` back, so restoring erases
/// nothing. Returns whether a version was kept.
public struct ArtifactKeepRestored: InternalMethod {
    public static let name = "artifact.keepRestored"
    public typealias Result = Bool
    public var path: String, from: Int
    public init(path: String, from: Int) {
        self.path = path
        self.from = from
    }
}

/// What chat `session` spent from `from` to `to` (seconds since 1970): one round of marks on a page, from their send
/// to its turn's end. nil when nothing is known (an agent whose spending Kelp doesn't read).
public struct ArtifactRoundCost: InternalMethod {
    public static let name = "artifact.roundCost"
    public typealias Result = ArtifactCost.Spent?
    public var session: String, from: Double, to: Double
    public init(session: String, from: Double, to: Double) {
        self.session = session
        self.from = from
        self.to = to
    }
}

/// Renames the page (`path`, its file) as the user typed it: its title in the Artifacts panel and its bar. Returns
/// whether it was renamed.
public struct ArtifactRename: InternalMethod {
    public static let name = "artifact.rename"
    public typealias Result = Bool
    public var path: String, title: String
    public init(path: String, title: String) {
        self.path = path
        self.title = title
    }
}

/// Tags a page (`folder`, the artifact's folder), untags it, moves it to the archive or out of it, as the user does in
/// Artifacts Overview and an agent does with `kelp artifact tag|untag|archive|unarchive`. An agent's call names its
/// `session`: the page keeps what it had before (`ArtifactAgentChange`), and `undo` puts that back; `keep` (the user
/// closing the change's bar) forgets it, so a later change by that chat is undone on its own. Returns the page's tags
/// after the change.
public struct ArtifactChange: RPCMethod {
    public static let name = "artifact.change"
    public typealias Result = [String]
    public var folder: String
    public var add: [String]?, remove: [String]?, archived: Bool?
    public var session: String?, undo: Bool?, keep: Bool?
    public init(
        folder: String, add: [String]? = nil, remove: [String]? = nil, archived: Bool? = nil, session: String? = nil,
        undo: Bool? = nil, keep: Bool? = nil
    ) {
        self.folder = folder
        self.add = add
        self.remove = remove
        self.archived = archived
        self.session = session
        self.undo = undo
        self.keep = keep
    }
}

/// Keeps the files an agent uploaded for its pages (`upload_asset`, from its hook), by their id on the service, in the
/// project that holds `cwd`: Kelp's copies of the pages show them without the network. Returns how many were kept.
public struct ArtifactKeepAssets: InternalMethod {
    public static let name = "artifact.keepAssets"
    public typealias Result = Int
    public struct Asset: Codable, Equatable, Sendable {
        public var path: String, id: String
        public init(path: String, id: String) {
            self.path = path
            self.id = id
        }
    }
    public var cwd: String, session: String?, assets: [Asset]
    public init(cwd: String, session: String?, assets: [Asset]) {
        self.cwd = cwd
        self.session = session
        self.assets = assets
    }
}

/// Makes the copy of a page on a service (`folder`, the artifact's) that opens without the network: its pictures and
/// styles beside it, linked from there. Returns that file, which opens in a page's tab.
public struct ArtifactOffline: InternalMethod {
    public static let name = "artifact.offline"
    public typealias Result = String
    public var folder: String
    public init(folder: String) { self.folder = folder }
}

/// `kelp artifact ask`: the agent's question about element `id` of a page (`path`, its file), put on it as a mark the
/// user answers in its note; the answer comes with the user's next marks. Returns the mark's number.
public struct ArtifactAsk: RPCMethod {
    public static let name = "artifact.ask"
    public typealias Result = Int
    public var path: String, id: String, text: String
    public init(path: String, id: String, text: String) {
        self.path = path
        self.id = id
        self.text = text
    }
}

/// `kelp artifact suggest`: what the agent suggests the user asks next about a page (`path`, its file), three at most,
/// shown under its marks until the next send; a click makes one a mark to send.
public struct ArtifactSuggest: RPCMethod {
    public static let name = "artifact.suggest"
    public typealias Result = Bool
    public var path: String, lines: [String]
    public init(path: String, lines: [String]) {
        self.path = path
        self.lines = lines
    }
}

/// `kelp artifact reply`: an agent's word on mark `id` of a page (`path`, its file), shown under the mark. The mark
/// must be with the agent or waiting for the user's check; closing it is the user's.
public struct ArtifactReply: RPCMethod {
    public static let name = "artifact.reply"
    public typealias Result = Bool
    public var path: String, id: Int, text: String
    public init(path: String, id: Int, text: String) {
        self.path = path
        self.id = id
        self.text = text
    }
}
