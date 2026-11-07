import Foundation

// Agents → app: `kelp open`, `kelp run`… call `ui.*`; the daemon relays them to the app as `event.ui` (with `action`).

/// How many Kelp windows were told.
public struct Delivered: Codable, Sendable, Equatable {
    public var delivered: Int
    public init(delivered: Int) { self.delivered = delivered }
}

/// What the app shows (workspace, tabs, extensions, commands), for agents to read back with `ui.state`. Only Kelp's window.
public struct UIPublish: InternalMethod {
    public static let name = "ui.publish"
    public typealias Result = Done
    public var state: JSONValue
    public init(state: JSONValue) { self.state = state }
}
/// What the app last published (an empty object when no app is connected).
public struct UIStateGet: InternalMethod {
    public static let name = "ui.state"
    public typealias Result = JSONValue
    public init() {}
}
/// A tab for `uri` in the app: beside the focused one (`split` right|down), in workspace `worktreeId`; `focus` brings Kelp
/// forward and shows that workspace.
public struct UIOpen: InternalMethod {
    public static let name = "ui.open"
    public typealias Result = Delivered
    public var uri: String, split: String?, focus: Bool?, worktreeId: String?
    public init(uri: String, split: String? = nil, focus: Bool? = nil, worktreeId: String? = nil) {
        self.uri = uri
        self.split = split
        self.focus = focus
        self.worktreeId = worktreeId
    }
}
/// Runs the app's command `id` (as in the palette) with `args`.
public struct UICommand: InternalMethod {
    public static let name = "ui.command"
    public typealias Result = Delivered
    public var id: String, args: JSONValue?
    public init(id: String, args: JSONValue? = nil) {
        self.id = id
        self.args = args
    }

    /// The app's commands an agent may run: what shows something or moves around (panes, tabs, panels, pages), the
    /// window's picture (`kelp shot`) and an extensions reload (`kelp ext reload`). Each by its id: an extension names its
    /// own commands, so a prefix would let one in.
    public static let forAgents: Set<String> = [
        "agents.history", "agents.nextNeedingYou", "agents.sideBySide", "agents.usage",
        "editor.findReferences", "editor.fold", "editor.foldAll", "editor.goToLine", "editor.jumpToDefinition",
        "editor.nextProblem", "editor.nextTab", "editor.previousProblem", "editor.previousTab", "editor.showHover",
        "editor.unfold", "editor.unfoldAll",
        "files.findByName", "files.findInWorkspace", "files.quickOpen", "files.showProblems",
        "forge.openCI", "forge.openIssues", "forge.openPulls", "forge.openRepo",
        "help.extensionGuide", "help.guide", "markdown.cycleView", "routines.show", "scripts.openPage",
        "view.biggerText", "view.defaultTextSize", "view.equalizePanes", "view.maximizePane", "view.nextPane",
        "view.paneAbove",
        "view.paneBelow", "view.paneLeft", "view.paneRight", "view.previousPane", "view.smallerText",
        "workbench.commandPalette", "workbench.openExtensions", "workbench.openSettings", "workbench.showPanel",
        "workbench.toggleFocusMode", "workbench.toggleInspector", "workbench.toggleSidebar",
        "workspace.back", "workspace.forward", "workspace.next", "workspace.previous", "workspace.revealInFinder",
        "workspace.switch", "window.shot", "extensions.reload"
    ]
}

/// `kelp browser`: `action` (open, snapshot, click, type, eval, screenshot, wait) on the browser tab of workspace
/// `worktreeId`, done by the app, whose answer is the result. It waits for the page, up to `wait` seconds.
public struct UIBrowser: InternalMethod {
    public static let name = "ui.browser"
    public typealias Result = JSONValue
    /// How long the daemon waits for the app's answer; the call itself a little longer.
    public static let wait: TimeInterval = 60
    public static var timeout: TimeInterval? { wait + 5 }
    public var action: String, args: JSONValue?, worktreeId: String?
    public init(action: String, args: JSONValue? = nil, worktreeId: String? = nil) {
        self.action = action
        self.args = args
        self.worktreeId = worktreeId
    }
}
/// The app's answer to `event.ui.browser` (its `request`): the result, or what went wrong. Only Kelp's window.
public struct UIBrowserReply: InternalMethod {
    public static let name = "ui.browser.reply"
    public typealias Result = Done
    public var request: String, result: JSONValue?, error: String?
    public init(request: String, result: JSONValue? = nil, error: String? = nil) {
        self.request = request
        self.result = result
        self.error = error
    }
}

/// An agent's prompt in a tab of the app (`kelp edit`, the tab's `prompt:` URI).
public enum Prompts {
    /// Beside the file: written when the tab closes.
    public static let done = ".kelp-done"
    public static func uriBody(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    }
}
