/// The settings more than one side reads: the daemon or the CLI, or the shell for a built-in that owns it (Settings'
/// labels and pictures, the theme). Each is declared once, its default with it; a setting only one module reads is
/// declared there, in an extension of this. The rows in Settings are the built-ins' (`Builtins.s`).
public enum SettingKeys {
    // Agents
    public static let defaultAgent = Setting("agents.default", "claude")
    public static let editInKelp = Setting("agents.editInKelp", true)
    public static let hibernateMinutes = Setting<Double>("sessions.hibernateMinutes", 0)
    public static let updateIdle = Setting("agents.updateIdle", true)
    public static let recap = Setting("agents.recap", true)
    public static let childReports = Setting("agents.childReports", true)
    public static let keepAwake = Setting("power.keepAwake", "agents")
    public static let artifactsWhere = Setting("artifacts.where", "agent")
    public static let accounts = Setting<[JSONValue]>("accounts.profiles", [])

    // Plan limits
    public static let readPlans = Setting("usage.readPlans", true)
    /// What Show plan limits was called before; the daemon still reads it while the new one isn't set.
    public static let readClaudePlan = Setting("usage.readClaudePlan", true)
    public static let usageLimits = Setting("usage.limits", "all")
    public static let alertAt = Setting("usage.alertAt", "80")

    // Claude Code skills
    public static let skillExtensions = Setting("agents.skills.extensions", true)
    public static let skillSettings = Setting("agents.skills.settings", true)
    public static let skillTerminals = Setting("agents.skills.terminals", true)
    public static let skillAgents = Setting("agents.skills.agents", true)
    public static let skillArtifacts = Setting("agents.skills.artifacts", true)
    public static let skillVM = Setting("agents.skills.vm", true)
    /// "auto", "on" or "off"; true and false before it was a choice.
    public static let skillBrowser = Setting("agents.skills.browser", "auto")

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
    public static let rulers = Setting("editor.rulers", "")
    public static let renderWhitespace = Setting("editor.renderWhitespace", "selection")
    public static let bracketColors = Setting("editor.bracketColors", false)
    public static let indentGuides = Setting("editor.indentGuides", false)
    public static let markdownMode = Setting("markdown.defaultMode", "preview")

    // Source Control
    public static let branchPrefix = Setting("git.branchPrefix", "")
    public static let worktreesFolder = Setting("worktrees.folder", "")
    public static let ciBranchChip = Setting("workbench.ci.branchChip", "icon")
    /// "+6 −2" and "#128" beside folders: the shell's changes, Git's pull requests.
    public static let gitBadges = Setting("workbench.sidebar.gitBadges", true)

    // Extensions
    /// nil: settings.json has no list yet, so the built-ins off by default are off.
    public static let disabledExtensions = Setting<[String]?>("extensions.disabled", nil)
    public static let extensionLibrary = Setting("extensions.library", IDE.libraryIndex)
}
