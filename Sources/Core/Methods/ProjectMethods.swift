import Foundation

// Methods for a project's .kelp.yaml commands, remote projects, settings, usage and past conversations.

/// Lists everything that trusting the project's .kelp.yaml would allow.
public struct ScriptsList: RPCMethod {
    public static let name = "scripts.list"
    public struct Script: Codable, Sendable, Equatable {
        public var name: String, command: String
        public init(name: String, command: String) {
            self.name = name
            self.command = command
        }
    }
    public struct Result: Codable, Sendable, Equatable {
        public var scripts: [Script], setup: String?, tabs: [String], shared: [String], recipes: [String: String],
            issueCommand: String?
        /// The file's `layout.<name>` lines in order, each as written ("claude | page / run"). They are the project's
        /// group templates.
        public var layouts: [Script]?
        /// The digest of exactly the text read, so `scripts.trust` trusts what was shown and not a later version.
        public var digest: String
        public var trusted: Bool, file: String
        public init(
            scripts: [Script], setup: String?, tabs: [String], shared: [String], recipes: [String: String],
            issueCommand: String?, layouts: [Script]? = nil,
            digest: String, trusted: Bool, file: String
        ) {
            self.layouts = layouts
            self.scripts = scripts
            self.setup = setup
            self.tabs = tabs
            self.shared = shared
            self.recipes = recipes
            self.issueCommand = issueCommand
            self.digest = digest
            self.trusted = trusted
            self.file = file
        }
    }
    public var worktreeId: String
    public init(worktreeId: String) { self.worktreeId = worktreeId }
}
/// Allows the project's .kelp.yaml to run, as it was shown (`digest` from scripts.list). Only Kelp's window may call
/// it.
public struct ScriptsTrust: RPCMethod {
    public static let name = "scripts.trust"
    public typealias Result = Done
    public var worktreeId: String, digest: String?
    public init(worktreeId: String, digest: String?) {
        self.worktreeId = worktreeId
        self.digest = digest
    }
}
/// Runs command `name` (or "setup") in the workspace's folder and returns the session.
public struct ScriptsRun: RPCMethod, StartsSized {
    public static let name = "scripts.run"
    public typealias Result = Session
    public var worktreeId: String, name: String, cols: Int?, rows: Int?
    public init(worktreeId: String, name: String, cols: Int? = nil, rows: Int? = nil) {
        self.worktreeId = worktreeId
        self.name = name
        self.cols = cols
        self.rows = rows
    }
}

/// Something the project's own files say can be run: a package.json script, a Makefile target, a compose service, a
/// Python app… (`run.detect`). It runs only when someone picks it (`run.start`), never just because a project was
/// opened.
public struct RunOption: Codable, Sendable, Equatable {
    /// "folder|file|name", which stays the same while the file keeps the entry, so a choice can be remembered.
    public var id: String
    public var name: String, command: String
    /// Where the option runs inside the workspace ("" is the workspace's own folder).
    public var folder: String
    /// The file the option comes from ("package.json", "Makefile", "compose.yaml"…).
    public var source: String
    /// "run", "test", "build", "lint", "install" (the dependencies), or "other".
    public var kind: String
    /// What the entry says, when that isn't the command itself (a script's body, a service's port).
    public var detail: String?
    /// A program the option needs that isn't on the PATH of the machine it runs on.
    public var missing: String?
    public init(
        id: String, name: String, command: String, folder: String, source: String, kind: String, detail: String? = nil,
        missing: String? = nil
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.folder = folder
        self.source = source
        self.kind = kind
        self.detail = detail
        self.missing = missing
    }
}
/// Returns what the workspace's project files offer to run (on the host, for a remote project), and the likeliest dev
/// server.
public struct RunDetect: RPCMethod {
    public static let name = "run.detect"
    public struct Result: Codable, Sendable, Equatable {
        public var options: [RunOption], guess: String?
        public init(options: [RunOption], guess: String?) {
            self.options = options
            self.guess = guess
        }
    }
    public var worktreeId: String
    public init(worktreeId: String) { self.worktreeId = worktreeId }
}
/// Runs option `id` (as run.detect gives it, read again now) in the workspace and returns the session. The first local
/// URL it prints comes as event.devserver. A remote project's runs go in tmux on the host, with their port forwarded to
/// this Mac.
public struct RunStart: RPCMethod, StartsSized {
    public static let name = "run.start"
    public typealias Result = Session
    public var worktreeId: String, id: String, cols: Int?, rows: Int?
    public init(worktreeId: String, id: String, cols: Int? = nil, rows: Int? = nil) {
        self.worktreeId = worktreeId
        self.id = id
        self.cols = cols
        self.rows = rows
    }
}

/// Returns whether a new Claude Code chat in this workspace gets Kelp's browser skill, and why. It follows
/// `agents.skills.browser` (auto, on or off), unless the project has its own choice (UI state `browser.choice.<repo>`,
/// "on" or "off").
public struct SkillsBrowser: InternalMethod {
    public static let name = "skills.browser"
    public typealias Result = BrowserSkill
    public var worktreeId: String
    public init(worktreeId: String) { self.worktreeId = worktreeId }
}
public struct BrowserSkill: Codable, Sendable, Equatable {
    /// Why the setting is on or off, when the reason isn't that a web app was found. The words are given by `why`, and
    /// the app translates them.
    public enum Reason: String, Codable, CaseIterable, Sendable {
        case project = "set for this project", always = "Always, in Settings", never = "Never, in Settings"
        case used = "an agent used it here", localPage = "a local page is open here", noWebApp = "no web app found"
    }
    /// The project's own choice (UI state `browser.choice.<repo>`).
    public enum Choice: String, Codable, CaseIterable, Sendable { case on, off }
    /// `why` is a `Reason`'s words, or the web app found ("Vite in package.json"). `choice` is the project's own
    /// choice, nil when it follows Settings. `hint` means the skill is off but the agent is told where the guide is
    /// (never when Settings says Never).
    public var on: Bool, why: String, choice: Choice?, hint: Bool
    public init(on: Bool, _ reason: Reason, choice: Choice? = nil, hint: Bool = false) {
        self.init(on: on, why: reason.rawValue, choice: choice, hint: hint)
    }
    /// The skill is on because Kelp found a web app, and `framework` says which ("Vite in package.json").
    public init(framework: String) { self.init(on: true, why: framework) }
    private init(on: Bool, why: String, choice: Choice? = nil, hint: Bool = false) {
        self.on = on
        self.why = why
        self.choice = choice
        self.hint = hint
    }
    public var reason: Reason? { Reason(rawValue: why) }
    /// The web app found, when that is the reason.
    public var framework: String? { reason == nil ? why : nil }
    /// The hover card's line, as a session keeps it (`Session.browser`). `parse` reads it back.
    public var line: String { (on ? "on · " : "off · ") + why }
    public static func parse(_ line: String) -> BrowserSkill? {
        let parts = line.components(separatedBy: " · ")
        guard parts.count == 2, ["on", "off"].contains(parts[0]) else { return nil }
        return BrowserSkill(on: parts[0] == "on", why: parts[1])
    }
    /// The UI state key for the project's choice.
    public static func choiceKey(_ repo: String) -> String { "browser.choice.\(repo)" }
}

/// Adds a project on `host` at `path`, with a local folder that stands for the one there. `init` makes a plain folder a
/// repository.
public struct RepoAddRemote: RPCMethod {
    public static let name = "repo.addRemote"
    public typealias Result = Repo
    public var host: String, path: String, `init`: Bool?
    public init(host: String, path: String, `init`: Bool? = nil) {
        self.host = host
        self.path = path
        self.`init` = `init`
    }
}
/// Why a tab shows a reason instead of a file's text. The same rule applies to a file on this Mac and to one on a
/// remote project's host, and `files.read` fails with it as its error's `data`.
public enum Unopenable: Codable, Sendable, Equatable {
    /// A pipe or a device (/dev/zero), which would block or never end when read.
    case special
    /// A file past `openLimit` (a 300 MB log would hang the window), with its size in bytes.
    case tooBig(Int)
    /// Not UTF-8 text. If it were decoded anyway, U+FFFD would stand for the bytes, and a save would write that back.
    case binary
    /// A file bigger than this isn't opened. From 5 MB a file opens read only (`CodeEditor.readOnlyLimit`).
    public static let openLimit = 50 << 20

    public var error: RPCError {
        let message =
            switch self {
            case .special: "Not a regular file (a pipe or a device)."
            case .tooBig(let bytes): "Too big to open (\(bytes) bytes)."
            case .binary: "Not UTF-8 text (binary, or another encoding)."
            }
        return RPCError(code: -32001, message: message, data: try? JSONValue.from(self))
    }
    /// Reads the reason a daemon's error carries, when it is this kind of error.
    public init?(_ error: Error) {
        guard let data = (error as? RPCError)?.data, let reason = try? data.decode(Unopenable.self) else { return nil }
        self = reason
    }
}

/// Finds a remote project's own icon on its host, where `IconSearch` looks, and returns the path of its copy in the
/// project's local folder, so it shows without the host. Returns null when there is none. A copy kept from before is
/// returned at once, and the icon is looked for again in the background.
public struct RepoIcon: InternalMethod {
    public static let name = "repo.icon"
    public typealias Result = String?
    public var path: String
    public init(path: String) { self.path = path }
}

/// Returns all settings (the keys of settings.json, flat and dotted).
public struct SettingsGet: InternalMethod {
    public static let name = "settings.get"
    public typealias Result = [String: JSONValue]
    public init() {}
}
/// Sets a setting and returns all settings. A null `value` resets the key.
public struct SettingsSet: InternalMethod {
    public static let name = "settings.set"
    public typealias Result = [String: JSONValue]
    public var key: String, value: JSONValue?
    public init(key: String, value: JSONValue?) {
        self.key = key
        self.value = value
    }
}

/// Lists past conversations, newest first, filtered by `query` (searched in `fullText` too) and `cwd`, at most
/// `limit`.
public struct HistoryList: RPCMethod {
    public static let name = "history.list"
    public typealias Result = [AgentSessionInfo]
    public var query: String?, fullText: Bool?, cwd: String?, limit: Int?
    public init(query: String? = nil, fullText: Bool? = nil, cwd: String? = nil, limit: Int? = nil) {
        self.query = query
        self.fullText = fullText
        self.cwd = cwd
        self.limit = limit
    }
}
