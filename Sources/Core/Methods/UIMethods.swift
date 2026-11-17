import Foundation

// Calls from agents to the app. `kelp open`, `kelp run` and the like call `ui.*`, and the daemon relays them to the app
// as `event.ui` (with `action`).

/// The number of Kelp windows that were told.
public struct Delivered: Codable, Sendable, Equatable {
    public var delivered: Int
    public init(delivered: Int) { self.delivered = delivered }
}

/// What the app shows, as agents read it back (`kelp ui state`). It is empty when no app is connected.
public struct ShownUI: Codable, Sendable, Equatable {
    /// The workspace on screen.
    public let workspace: Workspace?
    public let focusedSession: String?, focusedFile: String?
    /// The editor area's tabs.
    public let editor: Editor?
    public let extensions: [Extension]?
    /// The palette's commands and the inspector's panels, as `kelp ui command` and `kelp open ext:` take them.
    public let commands: [Item]?, panels: [Item]?
    /// True when Kelp's window can't be seen (hidden, minimized or covered), so what only the window shows isn't read
    /// meanwhile.
    public let away: Bool?

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
    /// A tab (with its URI and title), or a command or panel (with its id and title).
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
        /// The extension's folder. nil for a built-in.
        public let path: String?
        /// Why the extension didn't load.
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
        extensions: [Extension]? = nil, commands: [Item]? = nil, panels: [Item]? = nil, away: Bool? = nil
    ) {
        self.workspace = workspace
        self.focusedSession = focusedSession
        self.focusedFile = focusedFile
        self.editor = editor
        self.extensions = extensions
        self.commands = commands
        self.panels = panels
        self.away = away
    }
}

/// Publishes what the app shows (workspace, tabs, extensions, commands), for agents to read back with `ui.state`. Only
/// Kelp's window calls it.
public struct UIPublish: InternalMethod {
    public static let name = "ui.publish"
    public typealias Result = Done
    public var state: ShownUI
    public init(state: ShownUI) { self.state = state }
}
/// Returns what the app last published, or an empty object when no app is connected.
public struct UIStateGet: InternalMethod {
    public static let name = "ui.state"
    public typealias Result = ShownUI
    public init() {}
}
/// Opens a tab for `uri` in the app, in workspace `worktreeId`, beside the focused tab when `split` is right or down.
/// `focus` brings Kelp forward and shows that workspace.
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

    /// The app's commands an agent may run: those that show something or move around (panes, tabs, panels), the
    /// window's picture (`kelp shot`), and an extensions reload (`kelp ext reload`). Each is listed by its id, because
    /// an extension names its own commands and a prefix would let those in. None of them opens a page tab (so the
    /// `scripts.openPage` of ⇧⌘O isn't listed), because that tab is logged in as the user and `kelp shot` can see it.
    /// An agent's page comes from `kelp browser open`, with cookies of its own.
    public static let forAgents: Set<String> = [
        "agents.history", "agents.nextNeedingYou", "agents.sideBySide", "agents.usage",
        "editor.findReferences", "editor.fold", "editor.foldAll", "editor.goToLine", "editor.jumpToDefinition",
        "editor.nextProblem", "editor.nextTab", "editor.previousProblem", "editor.previousTab", "editor.showHover",
        "editor.unfold", "editor.unfoldAll",
        "files.findByName", "files.findInWorkspace", "files.quickOpen", "files.showProblems",
        "forge.openCI", "forge.openIssues", "forge.openPulls", "forge.openRepo",
        "help.extensionGuide", "help.guide", "markdown.cycleView", "routines.show",
        "view.biggerText", "view.defaultTextSize", "view.equalizePanes", "view.maximizePane", "view.nextPane",
        "view.paneAbove",
        "view.paneBelow", "view.paneLeft", "view.paneRight", "view.previousPane", "view.smallerText",
        "workbench.commandPalette", "workbench.openExtensions", "workbench.openSettings", "workbench.showPanel",
        "workbench.toggleFocusMode", "workbench.toggleInspector", "workbench.toggleSidebar",
        "workspace.back", "workspace.forward", "workspace.next", "workspace.previous", "workspace.revealInFinder",
        "workspace.switch", "window.shot", "extensions.reload"
    ]
}

/// The actions `kelp browser` performs on a page (`UIBrowser.action`), named in words that the CLI, the shell and the
/// page tab share.
public enum BrowserAction: String, Codable, CaseIterable, Sendable {
    case open, snapshot, click, hover, type, press, upload, dialog, scroll, back, reload, eval, viewport, screenshot,
        wait, drag
    case console, network, info
    /// Records the page. `args.path` (.mp4, .mov or .gif) starts a recording, `args.stop` ends it, and the answer's
    /// `path` is the file.
    case record
    /// The agent hands its page to the user and says what for (`args.text`), and the agent's row asks the user
    /// (`UIBrowserAsk`). The answer (`args.ended`: allow, deny, none, gone) takes the question off the page.
    case ask
}

/// `kelp browser` runs `action` on the browser tab of workspace `worktreeId`. The app performs it, and the app's answer
/// is the result. It waits for the page for up to `wait` seconds.
public struct UIBrowser: InternalMethod {
    public static let name = "ui.browser"
    public typealias Result = JSONValue
    /// How long the daemon waits for the app's answer. The call itself waits a little longer.
    public static let wait: TimeInterval = 60
    public static var timeout: TimeInterval? { wait + 5 }
    public var action: BrowserAction, args: JSONValue?, worktreeId: String?
    public init(action: BrowserAction, args: JSONValue? = nil, worktreeId: String? = nil) {
        self.action = action
        self.args = args
        self.worktreeId = worktreeId
    }
}
/// `kelp browser ask <question>`: the agent hands its page to the user and waits until the user is done (Done on the
/// page, Allow on the row), declines (Deny), or `wait` passes. The answer is the page at that point, plus `answer`.
public struct UIBrowserAsk: InternalMethod {
    public static let name = "ui.browser.ask"
    public typealias Result = JSONValue
    public static let wait: TimeInterval = 600
    public static var timeout: TimeInterval? { wait + UIBrowser.wait + 10 }
    public var question: String, args: JSONValue?, worktreeId: String?
    /// Returns the question that the agent's row and its notification ask, where Allow means Done. Done on the page
    /// answers it too.
    public static func rowQuestion(_ question: String) -> String { "On its page: \(question)" }
    public init(question: String, args: JSONValue? = nil, worktreeId: String? = nil) {
        self.question = question
        self.args = args
        self.worktreeId = worktreeId
    }
}

/// The app's answer to a request the daemon relayed to it (`event.ui.browser`, `event.artifact.check`), with the result
/// or what went wrong. Only Kelp's window calls it.
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

/// Opens an agent's prompt in a tab of the app (`kelp edit`, the tab's `prompt:` URI).
public enum Prompts {
    /// The suffix of a marker file beside the prompt file, written when the tab closes.
    public static let done = ".kelp-done"
    public static func uriBody(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    }
}

/// Reads what the app restores (`UIState`). With `key`, it returns the value or null. With `prefix`, it returns
/// {key: value} for every key that starts with it.
public struct StateGet: InternalMethod {
    public static let name = "state.get"
    public typealias Result = JSONValue
    public var key: String?, prefix: String?
    public init(key: String? = nil, prefix: String? = nil) {
        self.key = key
        self.prefix = prefix
    }
}

/// Sets a UI state key. A nil (or null) value deletes the key.
public struct StateSet: InternalMethod {
    public static let name = "state.set"
    public typealias Result = Done
    public var key: String, value: JSONValue?
    public init(key: String, value: JSONValue?) {
        self.key = key
        self.value = value
    }
}
