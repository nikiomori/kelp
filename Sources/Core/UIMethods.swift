import Foundation

// Agents → app: `kelp open`, `kelp run`… call `ui.*`; the daemon relays them to the app as `event.ui` (with `action`).

/// How many Kelp windows were told.
public struct Delivered: Codable, Sendable, Equatable {
    public var delivered: Int
    public init(delivered: Int) { self.delivered = delivered }
}

/// What the app shows (workspace, tabs, extensions, commands), for agents to read back with `ui.state`. Only Kelp's window.
public struct UIPublish: InternalMethod {
    public static let name = "ui.publish"; public typealias Result = Done
    public var state: JSONValue
    public init(state: JSONValue) { self.state = state }
}
/// What the app last published (an empty object when no app is connected).
public struct UIStateGet: InternalMethod { public static let name = "ui.state"; public typealias Result = JSONValue; public init() {} }
/// A tab for `uri` in the app: beside the focused one (`split` right|down), in workspace `worktreeId`; `focus` brings Kelp
/// forward and shows that workspace.
public struct UIOpen: InternalMethod {
    public static let name = "ui.open"; public typealias Result = Delivered
    public var uri: String, split: String?, focus: Bool?, worktreeId: String?
    public init(uri: String, split: String? = nil, focus: Bool? = nil, worktreeId: String? = nil) {
        self.uri = uri; self.split = split; self.focus = focus; self.worktreeId = worktreeId
    }
}
/// Runs the app's command `id` (as in the palette) with `args`.
public struct UICommand: InternalMethod {
    public static let name = "ui.command"; public typealias Result = Delivered
    public var id: String, args: JSONValue?
    public init(id: String, args: JSONValue? = nil) { self.id = id; self.args = args }
}
