import Foundation

// What the daemon tells its clients without being asked: JSON-RPC notifications whose params are the event's fields.
// The names are wire contract like the methods' (rpc.json).

/// A notification from the daemon: `name` is its method, the type's fields its params.
public protocol RPCEvent: Codable, Sendable {
    static var name: String { get }
}

/// Every event the daemon sends.
public let rpcEvents: [any RPCEvent.Type] = [
    Session.self, OutputEvent.self, DevServerEvent.self, PortBusyEvent.self, ChangedEvent.self, CloneEvent.self,
    SettingsEvent.self, UIEvent.self, UIBrowserEvent.self, Repo.self, Worktree.self, RemovedEvent.self,
    GitEvent.self, PortsEvent.self, ActivityEvent.self, CIEvent.self, PREvent.self, ContextEvent.self,
    LimitsEvent.self, FileEvent.self, FilesEvent.self, CommandsEvent.self, SubagentsEvent.self, HostEvent.self,
    RoutinesEvent.self, ArtifactsEvent.self, MachinesEvent.self, MachineEvent.self
]

/// A session's record changed: the record is the event.
extension Session: RPCEvent { public static let name = "event.session" }

/// What a session printed, to a client attached with JSON (`session.attach`), not as a byte pipe.
public struct OutputEvent: RPCEvent {
    public static let name = "event.output"
    public var session: String, data: String   // data: base64
    public init(session: String, data: Data) {
        self.session = session
        self.data = data.base64EncodedString()
    }
}

/// A dev server in a workspace printed its local URL.
public struct DevServerEvent: RPCEvent {
    public static let name = "event.devserver"
    public var worktree: String, url: String, session: String
    public init(worktree: String, url: String, session: String) {
        self.worktree = worktree
        self.url = url
        self.session = session
    }
}

/// A run couldn't start: what it printed says `port` is taken.
public struct PortBusyEvent: RPCEvent {
    public static let name = "event.portBusy"
    public var worktree: String, port: Int, session: String
    public init(worktree: String, port: Int, session: String) {
        self.worktree = worktree
        self.port = port
        self.session = session
    }
}

/// Projects or workspaces changed: read the lists again. The params are just the word. Still sent for clients that read
/// lists; the changed records themselves come as `event.repo` / `event.worktree` / `event.removed`.
public enum ChangedEvent: String, RPCEvent, CaseIterable {
    public static let name = "event.changed"
    case repo, worktree
}

/// A line of `git clone`'s progress, to the connection that started the clone.
public struct CloneEvent: RPCEvent {
    public static let name = "event.clone"
    public var id: String, line: String
    public init(id: String, line: String) {
        self.id = id
        self.line = line
    }
}

/// settings.json changed (a set, or the file edited by hand): all of it now.
public struct SettingsEvent: RPCEvent {
    public static let name = "event.settings"
    public var settings: [String: JSONValue]
    public init(settings: [String: JSONValue]) { self.settings = settings }
}

/// An agent's `ui.open` / `ui.command`, relayed to the app: the request's fields and which it was.
public struct UIEvent: RPCEvent {
    public static let name = "event.ui"
    public var action: String
    public var uri: String?, split: String?, focus: Bool?, worktreeId: String?   // open
    public var id: String?, args: JSONValue?   // command
    public init(_ method: UIOpen) {
        action = "open"
        uri = method.uri
        split = method.split
        focus = method.focus
        worktreeId = method.worktreeId
    }
    public init(_ method: UICommand) {
        action = "command"
        id = method.id
        args = method.args
    }
}

/// An agent's `ui.browser`, relayed to the app: it answers with `ui.browser.reply` and the same `request`.
public struct UIBrowserEvent: RPCEvent {
    public static let name = "event.ui.browser"
    public var request: String, action: String, args: JSONValue?, worktreeId: String?
    public init(_ method: UIBrowser, request: String) {
        self.request = request
        action = method.action
        args = method.args
        worktreeId = method.worktreeId
    }
}

/// The wire form of an event: one encode, no JSONValue in between (output events are many).
public struct RPCNotification<E: RPCEvent>: Encodable {
    public var jsonrpc = "2.0"
    public let method = E.name
    public let params: E
    public init(_ event: E) { params = event }
}
