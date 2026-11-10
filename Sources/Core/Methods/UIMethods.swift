import Foundation

// Agents → app: `kelp open`, `kelp run`… call `ui.*`; the daemon relays them to the app as `event.ui` (with `action`).

/// How many Kelp windows were told.
public struct Delivered: Codable, Sendable, Equatable {
    public var delivered: Int
    public init(delivered: Int) { self.delivered = delivered }
}

/// What the app shows, as agents read it back (`kelp ui state`): nothing at all when no app is connected.
public struct ShownUI: Codable, Sendable, Equatable {
    /// The workspace on screen.
    public let workspace: Workspace?
    public let focusedSession: String?, focusedFile: String?
    /// The editor area's tabs.
    public let editor: Editor?
    public let extensions: [Extension]?
    /// The palette's commands and the inspector's panels: what `kelp ui command` and `kelp open ext:` take.
    public let commands: [Item]?, panels: [Item]?

    public struct Workspace: Codable, Sendable, Equatable {
        public let id: String, name: String, path: String, branch: String
        public init(id: String, name: String, path: String, branch: String) {
            self.id = id
            self.name = name
            self.path = path
            self.branch = branch
        }
    }
    public struct Editor: Codable, Sendable, Equatable {
        public let tabs: [Item]
        /// The focused tab's URI ("" for none).
        public let focused: String
        public init(tabs: [Item], focused: String) {
            self.tabs = tabs
            self.focused = focused
        }
    }
    /// A tab (its URI and title), a command or a panel (its id and title).
    public struct Item: Codable, Sendable, Equatable {
        public let id: String?, uri: String?, title: String
        public init(id: String? = nil, uri: String? = nil, title: String) {
            self.id = id
            self.uri = uri
            self.title = title
        }
    }
    public struct Extension: Codable, Sendable, Equatable {
        public let id: String, name: String, enabled: Bool, builtin: Bool
        /// Its folder; nil for a built-in.
        public let path: String?
        /// Why it didn't load.
        public let error: String?
        public init(id: String, name: String, enabled: Bool, builtin: Bool, path: String? = nil, error: String? = nil) {
            self.id = id
            self.name = name
            self.enabled = enabled
            self.builtin = builtin
            self.path = path
            self.error = error
        }
    }

    public init(
        workspace: Workspace? = nil, focusedSession: String? = nil, focusedFile: String? = nil, editor: Editor? = nil,
        extensions: [Extension]? = nil, commands: [Item]? = nil, panels: [Item]? = nil
    ) {
        self.workspace = workspace
        self.focusedSession = focusedSession
        self.focusedFile = focusedFile
        self.editor = editor
        self.extensions = extensions
        self.commands = commands
        self.panels = panels
    }
}

/// What the app shows (workspace, tabs, extensions, commands), for agents to read back with `ui.state`. Only Kelp's window.
public struct UIPublish: InternalMethod {
    public static let name = "ui.publish"
    public typealias Result = Done
    public var state: ShownUI
    public init(state: ShownUI) { self.state = state }
}
/// What the app last published (an empty object when no app is connected).
public struct UIStateGet: InternalMethod {
    public static let name = "ui.state"
    public typealias Result = ShownUI
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

/// What `kelp browser` does on a page (`UIBrowser.action`): the CLI's words, the shell's and the page tab's alike.
public enum BrowserAction: String, CaseIterable, Sendable {
    case open, snapshot, click, hover, type, press, upload, dialog, scroll, back, reload, eval, viewport, screenshot,
        wait
    case console, network, info
}

/// `kelp browser`: `action` (a `BrowserAction`) on the browser tab of workspace `worktreeId`, done by the app, whose
/// answer is the result. It waits for the page, up to `wait` seconds.
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

/// What the app restores (`UIState`): `key` → its value or null; `prefix` → {key: value} for every key that starts with it.
public struct StateGet: InternalMethod {
    public static let name = "state.get"
    public typealias Result = JSONValue
    public var key: String?, prefix: String?
    public init(key: String? = nil, prefix: String? = nil) {
        self.key = key
        self.prefix = prefix
    }
}

/// A nil (or null) value deletes the key.
public struct StateSet: InternalMethod {
    public static let name = "state.set"
    public typealias Result = Done
    public var key: String, value: JSONValue?
    public init(key: String, value: JSONValue?) {
        self.key = key
        self.value = value
    }
}
