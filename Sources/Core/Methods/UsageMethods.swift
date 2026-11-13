import Foundation

// usage.*: plan limits per account, and what the agents used, by day, model and project.

/// Per account: Claude's 5-hour block, today and the week; Codex's limits (cached for a minute unless `force`); the plan
/// limits the agents' own /usage screens show.
public struct UsageGet: InternalMethod {
    public static let name = "usage.get"
    /// Tokens and their API price over a span (dates as seconds since 1970).
    public struct Block: Codable, Sendable, Equatable {
        public var start: Double, end: Double, input: Int, output: Int, cacheWrite: Int, cacheRead: Int, cost: Double,
            models: [String]
        public init(
            start: Double, end: Double, input: Int, output: Int, cacheWrite: Int, cacheRead: Int, cost: Double,
            models: [String]
        ) {
            self.start = start
            self.end = end
            self.input = input
            self.output = output
            self.cacheWrite = cacheWrite
            self.cacheRead = cacheRead
            self.cost = cost
            self.models = models
        }
    }
    public struct Claude: Codable, Sendable, Equatable {
        public var account: String, today: Block, week: Block
        /// The 5-hour block now, if one is running.
        public var block: Block?
        public init(account: String, today: Block, week: Block, block: Block?) {
            self.account = account
            self.today = today
            self.week = week
            self.block = block
        }
    }
    /// Codex's own limits from its latest log line (percent used, resets as seconds since 1970).
    public struct Codex: Codable, Sendable, Equatable {
        public var observedAt: Double, primaryUsedPercent: Double?, primaryResetsAt: Double?,
            secondaryUsedPercent: Double?, secondaryResetsAt: Double?
        /// Each window's length as Codex says it (nil from an older Codex: then the first is 5 hours, the second a week).
        public var primaryWindowMinutes: Double?, secondaryWindowMinutes: Double?
        public init(
            observedAt: Double, primaryUsedPercent: Double?, primaryResetsAt: Double?, secondaryUsedPercent: Double?,
            secondaryResetsAt: Double?,
            primaryWindowMinutes: Double? = nil, secondaryWindowMinutes: Double? = nil
        ) {
            self.observedAt = observedAt
            self.primaryUsedPercent = primaryUsedPercent
            self.primaryResetsAt = primaryResetsAt
            self.secondaryUsedPercent = secondaryUsedPercent
            self.secondaryResetsAt = secondaryResetsAt
            self.primaryWindowMinutes = primaryWindowMinutes
            self.secondaryWindowMinutes = secondaryWindowMinutes
        }
        /// The kind of limit a window is, as the other agents name theirs: "session" (5 hours), "week" or "month" (the free plan's one window).
        public static func kind(minutes: Double?, primary: Bool) -> String {
            guard let minutes else { return primary ? "session" : "week" }
            return minutes <= 24 * 60 ? "session" : minutes <= 8 * 24 * 60 ? "week" : "month"
        }
    }
    /// One limit as an agent shows it: kind ("session", "week", "week · Fable"…), percent used, when it resets.
    public struct Limit: Codable, Sendable, Equatable {
        public var kind: String, percent: Double, resets: String?
        /// When a session printed it (Claude's percentages from the last 12 hours); nil for a /usage reading.
        public var observedAt: Double?
        public init(kind: String, percent: Double, resets: String?, observedAt: Double? = nil) {
            self.kind = kind
            self.percent = percent
            self.resets = resets
            self.observedAt = observedAt
        }
    }
    public struct Result: Codable, Sendable, Equatable {
        public var claude: [Claude], codex: [Codex]
        /// By agent id: the latest /usage readings, and when they were read.
        public var plans: [String: [Limit]]?, plansReadAt: [String: Double]?
        public var claudeLimits: [Limit]?
        public init(
            claude: [Claude], codex: [Codex], plans: [String: [Limit]]? = nil, plansReadAt: [String: Double]? = nil,
            claudeLimits: [Limit]? = nil
        ) {
            self.claude = claude
            self.codex = codex
            self.plans = plans
            self.plansReadAt = plansReadAt
            self.claudeLimits = claudeLimits
        }
    }
    public var force: Bool?
    /// The token totals as last read, not read again (a scan reads every transcript): Kelp's window isn't seen.
    public var cachedTokens: Bool?
    public init(force: Bool? = nil, cachedTokens: Bool? = nil) {
        self.force = force
        self.cachedTokens = cachedTokens
    }
}
/// What Claude Code used over `days`, by day, model and project, priced as the API would.
public struct UsageReport: InternalMethod {
    public static let name = "usage.report"
    public struct Group: Codable, Sendable, Equatable {
        public var name: String, cost: Double, tokens: Int
        public init(name: String, cost: Double, tokens: Int) {
            self.name = name
            self.cost = cost
            self.tokens = tokens
        }
    }
    public struct Result: Codable, Sendable, Equatable {
        /// Most expensive first; `since` is the first day's start (seconds since 1970).
        public var days: [Group], models: [Group], projects: [Group], since: Double
        public init(days: [Group], models: [Group], projects: [Group], since: Double) {
            self.days = days
            self.models = models
            self.projects = projects
            self.since = since
        }
    }
    public var days: Int?
    public init(days: Int? = nil) { self.days = days }
}
/// What each agent used over `days`, read from its own logs on this Mac (Claude Code, Codex, Grok, Kimi Code, Copilot): by
/// day and agent, and by agent, model and project, priced as the API would (Grok as it says itself; 0 for a model with no
/// list price).
public struct UsageAgents: InternalMethod {
    public static let name = "usage.agents"
    public struct Day: Codable, Sendable, Hashable {
        public var day: String, agent: String, cost: Double, tokens: Int
        public init(day: String, agent: String, cost: Double, tokens: Int) {
            self.day = day
            self.agent = agent
            self.cost = cost
            self.tokens = tokens
        }
    }
    /// One agent over the span: its tokens by kind (`input` leaves the cache out) and its own models and projects.
    public struct Agent: Codable, Sendable, Equatable {
        public var id: String, cost: Double, tokens: Int
        public var input: Int, output: Int, cacheWrite: Int, cacheRead: Int
        public var models: [UsageReport.Group], projects: [UsageReport.Group]
        /// Its cost by kind of token, over the models with a list price (nil: none had one).
        public var costs: Costs?
        public init(
            id: String, cost: Double, tokens: Int, input: Int, output: Int, cacheWrite: Int, cacheRead: Int,
            models: [UsageReport.Group], projects: [UsageReport.Group], costs: Costs? = nil
        ) {
            self.id = id
            self.cost = cost
            self.tokens = tokens
            self.input = input
            self.output = output
            self.cacheWrite = cacheWrite
            self.cacheRead = cacheRead
            self.models = models
            self.projects = projects
            self.costs = costs
        }
    }
    /// What each kind of token cost, priced as the API would.
    public struct Costs: Codable, Sendable, Equatable {
        public var input: Double, output: Double, cacheWrite: Double, cacheRead: Double
        public init(input: Double, output: Double, cacheWrite: Double, cacheRead: Double) {
            self.input = input
            self.output = output
            self.cacheWrite = cacheWrite
            self.cacheRead = cacheRead
        }
        public static func + (a: Costs, b: Costs) -> Costs {
            Costs(
                input: a.input + b.input, output: a.output + b.output, cacheWrite: a.cacheWrite + b.cacheWrite,
                cacheRead: a.cacheRead + b.cacheRead)
        }
    }
    public struct Result: Codable, Sendable, Equatable {
        /// `days` by day ("yyyy-MM-dd") and agent id; agents and groups most expensive first; `since` is the first day's start.
        public var days: [Day], agents: [Agent], models: [UsageReport.Group], projects: [UsageReport.Group],
            since: Double
        /// The agents whose logs are read, in a fixed order (one not here keeps no counts on this Mac), and those whose
        /// own figure is the cost (the rest are priced from list prices). Nil from a kelpd before they were said.
        public var counted: [String]?, ownPrice: [String]?
        /// The same number of days before `since`, by agent (`name` is its id); nil past the year the logs are read for.
        public var previous: [UsageReport.Group]?
        public init(
            days: [Day], agents: [Agent], models: [UsageReport.Group], projects: [UsageReport.Group], since: Double,
            counted: [String]? = nil, ownPrice: [String]? = nil, previous: [UsageReport.Group]? = nil
        ) {
            self.days = days
            self.agents = agents
            self.models = models
            self.projects = projects
            self.since = since
            self.counted = counted
            self.ownPrice = ownPrice
            self.previous = previous
        }
    }
    public var days: Int?
    /// Only what was used in this project (a name from `projects`).
    public var project: String?
    public init(days: Int? = nil, project: String? = nil) {
        self.days = days
        self.project = project
    }
}
