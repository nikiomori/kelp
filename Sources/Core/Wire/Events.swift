import Foundation

// Events the daemon sends its clients without being asked. Each is a JSON-RPC notification whose params are the
// event's fields. Event names are part of the wire contract, like method names (rpc.json).

/// A notification from the daemon. `name` is the notification's method, and the type's fields are its params.
public protocol RPCEvent: Codable, Sendable {
    static var name: String { get }
}

/// Every event the daemon sends.
public let rpcEvents: [any RPCEvent.Type] = [
    Session.self, OutputEvent.self, DevServerEvent.self, PortBusyEvent.self, ChangedEvent.self, CloneEvent.self,
    SettingsEvent.self, UIEvent.self, UIBrowserEvent.self, Repo.self, Worktree.self, RemovedEvent.self,
    LandedEvent.self,
    GitEvent.self, PortsEvent.self, ActivityEvent.self, CIEvent.self, PREvent.self, ContextEvent.self,
    LimitsEvent.self, FileEvent.self, FilesEvent.self, CommandsEvent.self, SubagentsEvent.self, EditsEvent.self,
    HostEvent.self,
    RoutinesEvent.self, ArtifactsEvent.self, MachinesEvent.self, MachineEvent.self, DatabasesEvent.self,
    ArtifactCheckEvent.self, PhoneEvent.self, PRsEvent.self
]

/// Sent when a session's record changed. The record itself is the event.
extension Session: RPCEvent { public static let name = "event.session" }

/// What a session printed, sent to a client that attached with JSON (`session.attach`) rather than as a byte pipe.
public struct OutputEvent: RPCEvent {
    public static let name = "event.output"
    public var session: String, data: String   // `data` is base64.
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

/// Sent when a run couldn't start because its output says `port` is taken.
public struct PortBusyEvent: RPCEvent {
    public static let name = "event.portBusy"
    public var worktree: String, port: Int, session: String
    public init(worktree: String, port: Int, session: String) {
        self.worktree = worktree
        self.port = port
        self.session = session
    }
}

/// Sent when projects or workspaces changed, so clients read the lists again. The params are just the word. It is still
/// sent for clients that read lists, while the changed records themselves come as `event.repo`, `event.worktree` and
/// `event.removed`.
public enum ChangedEvent: String, RPCEvent, CaseIterable {
    public static let name = "event.changed"
    case repo, worktree
}

/// A line of `git clone` progress, sent to the connection that started the clone.
public struct CloneEvent: RPCEvent {
    public static let name = "event.clone"
    public var id: String, line: String
    public init(id: String, line: String) {
        self.id = id
        self.line = line
    }
}

/// Sent when settings.json changed, by a set call or by hand. It carries the whole file as it is now.
public struct SettingsEvent: RPCEvent {
    public static let name = "event.settings"
    public var settings: [String: JSONValue]
    public init(settings: [String: JSONValue]) { self.settings = settings }
}

/// An agent's `ui.open` or `ui.command` request, relayed to the app. It carries the request's fields and which of the
/// two it was.
public struct UIEvent: RPCEvent {
    public static let name = "event.ui"
    public var action: String
    public var uri: String?, split: String?, focus: Bool?, worktreeId: String?   // For `open`.
    public var id: String?, args: JSONValue?   // For `command`.
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

/// An agent's `ui.browser` request, relayed to the app. The app answers with `ui.browser.reply` and the same
/// `request`.
public struct UIBrowserEvent: RPCEvent {
    public static let name = "event.ui.browser"
    public var request: String, action: BrowserAction, args: JSONValue?, worktreeId: String?
    public init(_ method: UIBrowser, request: String) {
        self.request = request
        action = method.action
        args = method.args
        worktreeId = method.worktreeId
    }
}

/// Relays `artifact.check` to the window, which draws the canvas at `path` again and answers `request` with
/// `ui.browser.reply`.
public struct ArtifactCheckEvent: RPCEvent, Equatable {
    public static let name = "event.artifact.check"
    public var request: String, path: String
    public init(request: String, path: String) {
        self.request = request
        self.path = path
    }
}

/// The wire form of an event. It is encoded in one pass with no JSONValue in between, because output events are
/// many.
public struct RPCNotification<E: RPCEvent>: Encodable {
    public var jsonrpc = "2.0"
    public let method = E.name
    public let params: E
    public init(_ event: E) { params = event }
}
