import Foundation

// A project's .kelp.yaml commands, remote projects, settings, usage and past conversations.

/// Everything trusting the project's .kelp.yaml would allow.
public struct ScriptsList: RPCMethod {
    public static let name = "scripts.list"
    public struct Script: Codable, Sendable, Equatable {
        public var name: String, command: String
        public init(name: String, command: String) { self.name = name; self.command = command }
    }
    public struct Result: Codable, Sendable, Equatable {
        public var scripts: [Script], setup: String?, tabs: [String], shared: [String], recipes: [String: String], issueCommand: String?
        /// Of exactly the text read: `scripts.trust` trusts what was shown, not a later version.
        public var digest: String
        public var trusted: Bool, file: String
        public init(scripts: [Script], setup: String?, tabs: [String], shared: [String], recipes: [String: String], issueCommand: String?,
                    digest: String, trusted: Bool, file: String) {
            self.scripts = scripts; self.setup = setup; self.tabs = tabs; self.shared = shared; self.recipes = recipes
            self.issueCommand = issueCommand; self.digest = digest; self.trusted = trusted; self.file = file
        }
    }
    public var worktreeId: String
    public init(worktreeId: String) { self.worktreeId = worktreeId }
}
/// The project's .kelp.yaml as shown (`digest` from scripts.list) may run. Only from Kelp's window.
public struct ScriptsTrust: RPCMethod {
    public static let name = "scripts.trust"; public typealias Result = Done; public var worktreeId: String, digest: String?
    public init(worktreeId: String, digest: String?) { self.worktreeId = worktreeId; self.digest = digest }
}
/// Runs command `name` (or "setup") in the workspace's folder → the session.
public struct ScriptsRun: RPCMethod {
    public static let name = "scripts.run"; public typealias Result = Session; public var worktreeId: String, name: String
    public init(worktreeId: String, name: String) { self.worktreeId = worktreeId; self.name = name }
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
    public init(id: String, name: String, command: String, folder: String, source: String, kind: String, detail: String? = nil, missing: String? = nil) {
        self.id = id; self.name = name; self.command = command; self.folder = folder; self.source = source; self.kind = kind
        self.detail = detail; self.missing = missing
    }
}
/// What the workspace's project files offer to run (on the host, for a remote project), and the likeliest dev server.
public struct RunDetect: RPCMethod {
    public static let name = "run.detect"
    public struct Result: Codable, Sendable, Equatable {
        public var options: [RunOption], guess: String?
        public init(options: [RunOption], guess: String?) { self.options = options; self.guess = guess }
    }
    public var worktreeId: String
    public init(worktreeId: String) { self.worktreeId = worktreeId }
}
/// Runs option `id` (as run.detect gives it, read again now) in the workspace → the session. The first local URL it prints
/// comes as event.devserver; a remote project's runs go in tmux on the host, their port forwarded to this Mac.
public struct RunStart: RPCMethod {
    public static let name = "run.start"; public typealias Result = Session; public var worktreeId: String, id: String
    public init(worktreeId: String, id: String) { self.worktreeId = worktreeId; self.id = id }
}

/// A project on `host` at `path` (its local folder stands for the one there); `init` makes a plain folder a repository.
public struct RepoAddRemote: RPCMethod {
    public static let name = "repo.addRemote"; public typealias Result = Repo; public var host: String, path: String, `init`: Bool?
    public init(host: String, path: String, `init`: Bool? = nil) { self.host = host; self.path = path; self.`init` = `init` }
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
        let message = switch self {
        case .special: "Not a regular file (a pipe or a device)."
        case .tooBig(let n): "Too big to open (\(n) bytes)."
        case .binary: "Not UTF-8 text (binary, or another encoding)."
        }
        return RPCError(code: -32001, message: message, data: try? JSONValue.from(self))
    }
    /// The reason a daemon's error carries, when it's this kind of error.
    public init?(_ error: Error) {
        guard let d = (error as? RPCError)?.data, let u = try? d.decode(Unopenable.self) else { return nil }
        self = u
    }
}

/// A file in a remote project's folder, read on the host. Fails with an `Unopenable` error where a tab here would refuse
/// the file (a pipe, past the size limit, not UTF-8).
public struct FilesReadRemote: RPCMethod {
    public static let name = "files.readRemote"; public typealias Result = String; public var path: String
    public init(path: String) { self.path = path }
}
/// Writes `text` to that file on the host → null; → {changed: its text there} instead, unwritten, when it's no longer `base`
/// (an agent there edited it since it was read).
public struct FilesWriteRemote: RPCMethod {
    public static let name = "files.writeRemote"
    public struct Changed: Codable, Sendable, Equatable {
        public var changed: String
        public init(changed: String) { self.changed = changed }
    }
    public typealias Result = Changed?
    public var path: String, text: String, base: String?
    public init(path: String, text: String, base: String?) { self.path = path; self.text = text; self.base = base }
}
/// A remote project's own icon, looked for on its host where `IconSearch` looks → the path of its copy in the project's
/// folder here (it shows without the host), or null when it has none. A copy kept from before is answered at once and
/// looked for again in the background.
public struct RepoIcon: RPCMethod {
    public static let name = "repo.icon"; public typealias Result = String?; public var path: String
    public init(path: String) { self.path = path }
}

/// All settings (settings.json's keys, flat and dotted).
public struct SettingsGet: RPCMethod { public static let name = "settings.get"; public typealias Result = [String: JSONValue]; public init() {} }
/// A null `value` resets the key → all settings.
public struct SettingsSet: RPCMethod {
    public static let name = "settings.set"; public typealias Result = [String: JSONValue]; public var key: String, value: JSONValue?
    public init(key: String, value: JSONValue?) { self.key = key; self.value = value }
}

/// Per account: Claude's 5-hour block, today and the week; Codex's limits (cached for a minute unless `force`); the plan
/// limits the agents' own /usage screens show.
public struct UsageGet: RPCMethod {
    public static let name = "usage.get"
    /// Tokens and their API price over a span (dates as seconds since 1970).
    public struct Block: Codable, Sendable, Equatable {
        public var start: Double, end: Double, input: Int, output: Int, cacheWrite: Int, cacheRead: Int, cost: Double, models: [String]
        public init(start: Double, end: Double, input: Int, output: Int, cacheWrite: Int, cacheRead: Int, cost: Double, models: [String]) {
            self.start = start; self.end = end; self.input = input; self.output = output
            self.cacheWrite = cacheWrite; self.cacheRead = cacheRead; self.cost = cost; self.models = models
        }
    }
    public struct Claude: Codable, Sendable, Equatable {
        public var account: String, today: Block, week: Block
        /// The 5-hour block now, if one is running.
        public var block: Block?
        public init(account: String, today: Block, week: Block, block: Block?) {
            self.account = account; self.today = today; self.week = week; self.block = block
        }
    }
    /// Codex's own limits from its latest log line (percent used, resets as seconds since 1970).
    public struct Codex: Codable, Sendable, Equatable {
        public var observedAt: Double, primaryUsedPercent: Double?, primaryResetsAt: Double?, secondaryUsedPercent: Double?, secondaryResetsAt: Double?
        public init(observedAt: Double, primaryUsedPercent: Double?, primaryResetsAt: Double?, secondaryUsedPercent: Double?, secondaryResetsAt: Double?) {
            self.observedAt = observedAt; self.primaryUsedPercent = primaryUsedPercent; self.primaryResetsAt = primaryResetsAt
            self.secondaryUsedPercent = secondaryUsedPercent; self.secondaryResetsAt = secondaryResetsAt
        }
    }
    /// One limit as an agent shows it: kind ("session", "week", "week · Fable"…), percent used, when it resets.
    public struct Limit: Codable, Sendable, Equatable {
        public var kind: String, percent: Double, resets: String?
        /// When a session printed it (Claude's percentages from the last 12 hours); nil for a /usage reading.
        public var observedAt: Double?
        public init(kind: String, percent: Double, resets: String?, observedAt: Double? = nil) {
            self.kind = kind; self.percent = percent; self.resets = resets; self.observedAt = observedAt
        }
    }
    public struct Result: Codable, Sendable, Equatable {
        public var claude: [Claude], codex: [Codex]
        /// By agent id: the latest /usage readings, and when they were read.
        public var plans: [String: [Limit]]?, plansReadAt: [String: Double]?
        public var claudeLimits: [Limit]?
        public init(claude: [Claude], codex: [Codex], plans: [String: [Limit]]? = nil, plansReadAt: [String: Double]? = nil, claudeLimits: [Limit]? = nil) {
            self.claude = claude; self.codex = codex; self.plans = plans; self.plansReadAt = plansReadAt; self.claudeLimits = claudeLimits
        }
    }
    public var force: Bool?
    public init(force: Bool? = nil) { self.force = force }
}
/// What Claude Code used over `days`, by day, model and project, priced as the API would.
public struct UsageReport: RPCMethod {
    public static let name = "usage.report"
    public struct Group: Codable, Sendable, Equatable {
        public var name: String, cost: Double, tokens: Int
        public init(name: String, cost: Double, tokens: Int) { self.name = name; self.cost = cost; self.tokens = tokens }
    }
    public struct Result: Codable, Sendable, Equatable {
        /// Most expensive first; `since` is the first day's start (seconds since 1970).
        public var days: [Group], models: [Group], projects: [Group], since: Double
        public init(days: [Group], models: [Group], projects: [Group], since: Double) {
            self.days = days; self.models = models; self.projects = projects; self.since = since
        }
    }
    public var days: Int?
    public init(days: Int? = nil) { self.days = days }
}
/// Past conversations, newest first; `query` (in `fullText` too), `cwd`, at most `limit`.
public struct HistoryList: RPCMethod {
    public static let name = "history.list"; public typealias Result = [AgentSessionInfo]
    public var query: String?, fullText: Bool?, cwd: String?, limit: Int?
    public init(query: String? = nil, fullText: Bool? = nil, cwd: String? = nil, limit: Int? = nil) {
        self.query = query; self.fullText = fullText; self.cwd = cwd; self.limit = limit
    }
}
