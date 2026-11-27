/// The settings that more than one side reads: the daemon, the CLI, or the shell on behalf of the built-in that owns
/// the setting (Settings' labels and pictures, the theme). Each setting is declared once, together with its default. A
/// setting that only one module reads is declared in that module, in an extension of this enum. The rows in Settings
/// come from the built-ins (`Builtins.s`).
public enum SettingKeys {
    // Agents
    public static let defaultAgent = Setting("agents.default", Session.claudeAgent)
    public static let editInKelp = Setting("agents.editInKelp", true)
    public static let hibernateMinutes = Setting<Double>("sessions.hibernateMinutes", 0)
    /// Whether the agents Kelp's going down cut off mid-turn go on by themselves when it starts again, instead of
    /// waiting for Continue All.
    public static let resumeAfterCrash = Setting("sessions.resumeAfterCrash", false)
    public static let updateIdle = Setting("agents.updateIdle", true)
    public static let recap = Setting("agents.recap", true)
    public static let childReports = Setting("agents.childReports", true)
    public static let keepAwake = Setting("power.keepAwake", "agents")
    public static let accounts = Setting<[JSONValue]>("accounts.profiles", [])

    // Plan limits
    public static let readPlans = Setting("usage.readPlans", true)
    /// The old key of the "Show plan limits" setting. The daemon still reads it while the new key isn't set.
    public static let readClaudePlan = Setting("usage.readClaudePlan", true)
    public static let usageLimits = Setting("usage.limits", "all")
    public static let alertAt = Setting("usage.alertAt", "80")

    // Claude Code skills
    public static let skillExtensions = Setting("agents.skills.extensions", true)
    public static let skillSettings = Setting("agents.skills.settings", true)
    public static let skillTerminals = Setting("agents.skills.terminals", true)
    public static let skillAgents = Setting("agents.skills.agents", true)
    /// Which chats get Kelp's pages skill (docs, reviews). "auto" gives it to agents without artifacts of their own,
    /// and Claude Code's claude-artifacts counts as its own. "all" makes Claude Code use Kelp's pages too, and "off"
    /// turns the skill off. This setting replaced an on/off switch and `artifacts.where` (`SettingsStore.upgraded`).
    public static let skillArtifacts = Setting("agents.skills.artifacts", "auto")
    public static let skillVM = Setting("agents.skills.vm", true)
    public static let skillDatabases = Setting("agents.skills.databases", true)
    public static let skillRoutines = Setting("agents.skills.routines", true)
    public static let skillTasks = Setting("agents.skills.tasks", true)
    /// What agents may do with a database Kelp found, until the database's own menu says otherwise: "read", "ask" or
    /// "free".
    public static let databaseAccess = Setting("databases.agents", "ask")
    /// How many rows a statement returns to an agent unless the agent asks for more, and how many seconds a read may
    /// take.
    public static let databaseRows = Setting<Double>("databases.agentRows", 200)
    public static let databaseTimeout = Setting<Double>("databases.timeout", 15)
    /// The height of a table's rows: "compact" (20 pt, as in TablePlus), "normal" (24) or "comfortable" (28).
    public static let databaseDensity = Setting("databases.density", "compact")
    /// "auto", "on" or "off". Before it had three choices, this setting was true or false.
    public static let skillBrowser = Setting("agents.skills.browser", "auto")
    /// The sites where agents use the user's login from Kelp's browser (`AgentSites`).
    public static let agentSites = Setting<[JSONValue]>("browser.agentSites", [])

    // Notifications
    public static let onWaiting = Setting("agents.onWaiting", "sound")
    public static let remindAfter = Setting("agents.remindAfter", "10")
    public static let onFinish = Setting("agents.onFinish", "banner")
    public static let quietUnder = Setting<Double>("agents.quietUnder", 20)
    public static let onError = Setting("agents.onError", "sound")
    public static let holdBanners = Setting("agents.holdBanners", true)
    public static let dockStrip = Setting("agents.dockStrip", "always")
    public static let dockStripComesFor = Setting("agents.dockStrip.comesFor", "failures")
    public static let dockIcon = Setting("agents.dockIcon", "icon")
    public static let phoneURL = Setting("phone.url", "")
    public static let phoneDetails = Setting("phone.details", false)
    /// The relay that passes calls from phones to this Mac (Settings › Phone). Empty means off.
    public static let phoneRelay = Setting("phone.relay", "")
    /// How a phone reaches this Mac: "tailscale", "address" (the user's own address in `phone.address`) or "relay".
    /// Empty means off, or a relay when `phone.relay` names one, which is how Kelp 0.14 stored it.
    public static let phoneVia = Setting("phone.via", "")
    /// The address at which the user's own tunnel or proxy serves this Mac's phone page.
    public static let phoneAddress = Setting("phone.address", "")
    /// The localhost port that kelpd serves the phone page on, for Tailscale or a tunnel to point at.
    public static let phonePort = Setting<Double>("phone.port", 47611)
    /// Whether a paired phone may start a new agent (Settings › Phone). Answering agents that already run needs no
    /// switch.
    public static let phoneStartAgents = Setting("phone.startAgents", false)
    /// The address of Kelp's own relay, which the switch in Settings › Phone writes.
    public static let phoneRelayAddress = "https://phone.kelpide.com"

    // Terminal
    public static let terminalFontFamily = Setting("terminal.fontFamily", "")
    public static let terminalFontSize = Setting<Double>("terminal.fontSize", 13)
    public static let cursorStyle = Setting("terminal.cursorStyle", "block")
    public static let optionAsAlt = Setting("terminal.optionAsAlt", false)
    public static let cleanCopy = Setting("terminal.cleanCopy", true)
    public static let useGhosttyConfig = Setting("terminal.useGhosttyConfig", false)
    public static let tmux = Setting("terminal.tmux", false)

    // Editor
    public static let editorFontFamily = Setting("editor.fontFamily", "")
    public static let editorFontSize = Setting<Double>("editor.fontSize", 13)
    public static let wordWrap = Setting("editor.wordWrap", false)
    public static let wrappingIndent = Setting("editor.wrappingIndent", "same")
    /// Each language server's own `options` and `settings`, keyed by its command: `{ "gopls": { "settings": { … } } }`.
    /// The daemon also lists this key as one that only the user may set (`SettingsSet.usersOnly`).
    public static let languageServers = Setting("editor.languageServers", JSONValue.object([:]))
    public static let markdownMode = Setting("markdown.defaultMode", "preview")

    // Source Control
    public static let branchPrefix = Setting("git.branchPrefix", "")
    public static let worktreesFolder = Setting("worktrees.folder", "")
    public static let ciBranchChip = Setting("workbench.ci.branchChip", "icon")
    /// Whether to show "+6 −2" and "#128" beside folders: the line changes from the shell, and the pull request from
    /// Git.
    public static let gitBadges = Setting("workbench.sidebar.gitBadges", true)

    // Extensions
    /// nil means settings.json has no list yet, so the built-ins that are off by default stay off.
    public static let disabledExtensions = Setting<[String]?>("extensions.disabled", nil)
    public static let extensionLibrary = Setting("extensions.library", ExtensionFiles.libraryIndex)
}
