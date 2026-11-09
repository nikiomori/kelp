import Foundation

// A project's .kelp.yaml commands, remote projects, settings, usage and past conversations.

/// Everything trusting the project's .kelp.yaml would allow.
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
        /// Of exactly the text read: `scripts.trust` trusts what was shown, not a later version.
        public var digest: String
        public var trusted: Bool, file: String
        public init(
            scripts: [Script], setup: String?, tabs: [String], shared: [String], recipes: [String: String],
            issueCommand: String?,
            digest: String, trusted: Bool, file: String
        ) {
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
/// The project's .kelp.yaml as shown (`digest` from scripts.list) may run. Only from Kelp's window.
public struct ScriptsTrust: RPCMethod {
    public static let name = "scripts.trust"
    public typealias Result = Done
    public var worktreeId: String, digest: String?
    public init(worktreeId: String, digest: String?) {
        self.worktreeId = worktreeId
        self.digest = digest
    }
}
/// Runs command `name` (or "setup") in the workspace's folder → the session.
public struct ScriptsRun: RPCMethod {
    public static let name = "scripts.run"
    public typealias Result = Session
    public var worktreeId: String, name: String
    public init(worktreeId: String, name: String) {
        self.worktreeId = worktreeId
        self.name = name
    }
}

/// Something the project's own files say can be run: a package.json script, a Makefile target, a compose service, a
/// Python app… (`run.detect`). It runs only when someone picks it (`run.start`), never because a project was opened.
public struct RunOption: Codable, Sendable, Equatable {
    /// "folder|file|name": the same while the file keeps the entry, so a choice can be remembered.
    public var id: String
    public var name: String, command: String
    /// Where it runs, inside the workspace ("" is its own folder).
    public var folder: String
    /// The file it comes from ("package.json", "Makefile", "compose.yaml"…).
    public var source: String
    /// "run", "test", "build", "lint", "install" (the dependencies), or "other".
    public var kind: String
    /// What the entry says, when that isn't the command (a script's body, a service's port).
    public var detail: String?
    /// The program it needs that isn't on that machine's PATH.
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
/// What the workspace's project files offer to run (on the host, for a remote project), and the likeliest dev server.
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
/// Runs option `id` (as run.detect gives it, read again now) in the workspace → the session. The first local URL it prints
/// comes as event.devserver; a remote project's runs go in tmux on the host, their port forwarded to this Mac.
public struct RunStart: RPCMethod {
    public static let name = "run.start"
    public typealias Result = Session
    public var worktreeId: String, id: String
    public init(worktreeId: String, id: String) {
        self.worktreeId = worktreeId
        self.id = id
    }
}

/// Whether a new Claude Code chat in this workspace gets Kelp's browser skill, and why: `agents.skills.browser`
/// (auto / on / off), laid under the project's own choice (UI state `browser.choice.<repo>`: "on" / "off").
public struct SkillsBrowser: InternalMethod {
    public static let name = "skills.browser"
    public typealias Result = BrowserSkill
    public var worktreeId: String
    public init(worktreeId: String) { self.worktreeId = worktreeId }
}
public struct BrowserSkill: Codable, Sendable, Equatable {
    /// `why`: "Vite in package.json", "no web app found"… `choice`: the project's own, nil when it follows Settings.
    /// `hint`: off, but the agent is told where the guide is (not when Settings says Never).
    public var on: Bool, why: String, choice: String?, hint: Bool
    public init(on: Bool, why: String, choice: String? = nil, hint: Bool = false) {
        self.on = on
        self.why = why
        self.choice = choice
        self.hint = hint
    }
    /// The hover card's line.
    public var line: String { (on ? "on · " : "off · ") + why }
    /// The project's choice in UI state.
    public static func choiceKey(_ repo: String) -> String { "browser.choice.\(repo)" }
}

/// A project on `host` at `path` (its local folder stands for the one there); `init` makes a plain folder a repository.
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
/// Why a tab shows a reason instead of a file's text: one rule for a file on this Mac and one on a remote project's host
/// (`files.readRemote` fails with it as its error's `data`).
public enum Unopenable: Codable, Sendable, Equatable {
    /// A pipe or a device (/dev/zero): reading it would block or never end.
    case special
    /// Past `openLimit` (a 300 MB log would hang the window); its size in bytes.
    case tooBig(Int)
    /// Not UTF-8 text: decoded anyway, U+FFFD would stand for bytes that a save then writes back.
    case binary
    /// Bigger than this isn't opened (read only from 5 MB, `CodeEditor.readOnlyLimit`).
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
    /// The reason a daemon's error carries, when it's this kind of error.
    public init?(_ error: Error) {
        guard let data = (error as? RPCError)?.data, let reason = try? data.decode(Unopenable.self) else { return nil }
        self = reason
    }
}

/// A file in a remote project's folder, read on the host. Fails with an `Unopenable` error where a tab here would refuse
/// the file (a pipe, past the size limit, not UTF-8).
public struct FilesReadRemote: InternalMethod {
    public static let name = "files.readRemote"
    public typealias Result = String
    public var path: String
    public init(path: String) { self.path = path }
}
/// Writes `text` to that file on the host → null; → {changed: its text there} instead, unwritten, when it's no longer `base`
/// (an agent there edited it since it was read).
public struct FilesWriteRemote: InternalMethod {
    public static let name = "files.writeRemote"
    public struct Changed: Codable, Sendable, Equatable {
        public var changed: String
        public init(changed: String) { self.changed = changed }
    }
    public typealias Result = Changed?
    public var path: String, text: String, base: String?
    public init(path: String, text: String, base: String?) {
        self.path = path
        self.text = text
        self.base = base
    }
}
/// A remote project's own icon, looked for on its host where `IconSearch` looks → the path of its copy in the project's
/// folder here (it shows without the host), or null when it has none. A copy kept from before is answered at once and
/// looked for again in the background.
public struct RepoIcon: InternalMethod {
    public static let name = "repo.icon"
    public typealias Result = String?
    public var path: String
    public init(path: String) { self.path = path }
}

/// All settings (settings.json's keys, flat and dotted).
public struct SettingsGet: InternalMethod {
    public static let name = "settings.get"
    public typealias Result = [String: JSONValue]
    public init() {}
}
/// A null `value` resets the key → all settings.
public struct SettingsSet: InternalMethod {
    public static let name = "settings.set"
    public typealias Result = [String: JSONValue]
    public var key: String, value: JSONValue?
    public init(key: String, value: JSONValue?) {
        self.key = key
        self.value = value
    }
}

/// Past conversations, newest first; `query` (in `fullText` too), `cwd`, at most `limit`.
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
