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

/// `kelp browser`: `action` (open, snapshot, click, type, eval, screenshot, wait) on the browser tab of workspace
/// `worktreeId`, done by the app, whose answer is the result. It waits for the page, up to `wait` seconds.
public struct UIBrowser: InternalMethod {
    public static let name = "ui.browser"; public typealias Result = JSONValue
    /// How long the daemon waits for the app's answer; the call itself a little longer.
    public static let wait: TimeInterval = 60
    public static var timeout: TimeInterval? { wait + 5 }
    public var action: String, args: JSONValue?, worktreeId: String?
    public init(action: String, args: JSONValue? = nil, worktreeId: String? = nil) {
        self.action = action; self.args = args; self.worktreeId = worktreeId
    }
}
/// The app's answer to `event.ui.browser` (its `request`): the result, or what went wrong. Only Kelp's window.
public struct UIBrowserReply: InternalMethod {
    public static let name = "ui.browser.reply"; public typealias Result = Done
    public var request: String, result: JSONValue?, error: String?
    public init(request: String, result: JSONValue? = nil, error: String? = nil) { self.request = request; self.result = result; self.error = error }
}

/// An agent's prompt in a tab of the app (`kelp edit`, the tab's `prompt:` URI).
public enum Prompts {
    /// Beside the file: written when the tab closes.
    public static let done = ".kelp-done"
    public static func uriBody(_ path: String) -> String { path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path }
}
