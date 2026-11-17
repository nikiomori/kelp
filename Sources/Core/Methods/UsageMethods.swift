import Foundation

// The usage.* methods: plan limits per account, and what the agents used, by day, model and project.

/// Returns usage per account: Claude's 5-hour block, today and the week, Codex's limits (cached for a minute unless
/// `force`), and the plan limits that the agents' own /usage screens show.
public struct UsageGet: InternalMethod {
    public static let name = "usage.get"
    /// The tokens and their API price over a span, with dates as seconds since 1970.
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
        /// The current 5-hour block, if one is running.
        public var block: Block?
        public init(account: String, today: Block, week: Block, block: Block?) {
            self.account = account
            self.today = today
            self.week = week
            self.block = block
        }
    }
    /// Codex's own limits from its latest log line: the percent used, and the resets as seconds since 1970.
    public struct Codex: Codable, Sendable, Equatable {
        public var observedAt: Double, primaryUsedPercent: Double?, primaryResetsAt: Double?,
            secondaryUsedPercent: Double?, secondaryResetsAt: Double?
        /// Each window's length as Codex states it. An older Codex gives nil, and then the first window is 5 hours
        /// and the second a week.
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
        /// Returns the kind of limit a window is, named as the other agents name theirs: "session" (5 hours), "week",
        /// or "month" (the free plan's single window).
        public static func kind(minutes: Double?, primary: Bool) -> String {
            guard let minutes else { return primary ? "session" : "week" }
            return minutes <= 24 * 60 ? "session" : minutes <= 8 * 24 * 60 ? "week" : "month"
        }
    }
    /// One limit as an agent shows it: the kind ("session", "week", "week · Fable"…), the percent used, and when it
    /// resets.
    public struct Limit: Codable, Sendable, Equatable {
        public var kind: String, percent: Double, resets: String?
        /// When a session printed the limit (Claude's percentages from the last 12 hours). nil for a /usage reading.
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
        /// The latest /usage readings and when they were read, keyed by agent id.
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
    /// Returns the token totals as last read instead of reading them again, because a scan reads every transcript. It
    /// is set while Kelp's window can't be seen.
    public var cachedTokens: Bool?
    public init(force: Bool? = nil, cachedTokens: Bool? = nil) {
        self.force = force
        self.cachedTokens = cachedTokens
    }
}
/// Returns what each agent used over `days`, read from its own logs on this Mac (Claude Code, Codex, Grok, Kimi Code,
/// Copilot). It is split by day and agent, and by agent, model and project, and priced as the API would price it. Grok
/// is priced as it states itself, and a model with no list price costs 0.
public struct UsageAgents: InternalMethod {
    public static let name = "usage.agents"
    /// The cost and tokens of one model, project or agent (`name`) over the span.
    public struct Group: Codable, Sendable, Equatable {
        public var name: String, cost: Double, tokens: Int
        public init(name: String, cost: Double, tokens: Int) {
            self.name = name
            self.cost = cost
            self.tokens = tokens
        }
    }
    public struct Day: Codable, Sendable, Hashable {
        public var day: String, agent: String, cost: Double, tokens: Int
        public init(day: String, agent: String, cost: Double, tokens: Int) {
            self.day = day
            self.agent = agent
            self.cost = cost
            self.tokens = tokens
        }
    }
    /// One agent over the span: its tokens by kind (`input` leaves out the cache) and its own models and projects.
    public struct Agent: Codable, Sendable, Equatable {
        public var id: String, cost: Double, tokens: Int
        public var input: Int, output: Int, cacheWrite: Int, cacheRead: Int
        public var models: [Group], projects: [Group]
        /// The agent's cost by kind of token, over the models with a list price. nil when none had one.
        public var costs: Costs?
        public init(
            id: String, cost: Double, tokens: Int, input: Int, output: Int, cacheWrite: Int, cacheRead: Int,
            models: [Group], projects: [Group], costs: Costs? = nil
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
        public static func + (lhs: Costs, rhs: Costs) -> Costs {
            Costs(
                input: lhs.input + rhs.input, output: lhs.output + rhs.output,
                cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
                cacheRead: lhs.cacheRead + rhs.cacheRead)
        }
    }
    public struct Result: Codable, Sendable, Equatable {
        /// `days` is by day ("yyyy-MM-dd") and agent id. Agents and groups are sorted most expensive first. `since`
        /// is the start of the first day.
        public var days: [Day], agents: [Agent], models: [Group], projects: [Group],
            since: Double
        /// The agents whose logs are read, in a fixed order (an agent not listed keeps no counts on this Mac), and the
        /// agents whose own figure is used as the cost (the rest are priced from list prices). Nil from a kelpd older
        /// than these fields.
        public var counted: [String]?, ownPrice: [String]?
        /// The same number of days before `since`, by agent (`name` is the agent id). nil beyond the year the logs are
        /// read for.
        public var previous: [Group]?
        public init(
            days: [Day], agents: [Agent], models: [Group], projects: [Group], since: Double,
            counted: [String]? = nil, ownPrice: [String]? = nil, previous: [Group]? = nil
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
    /// Limits the answer to what was used in this project (a name from `projects`).
    public var project: String?
    public init(days: Int? = nil, project: String? = nil) {
        self.days = days
        self.project = project
    }
}
