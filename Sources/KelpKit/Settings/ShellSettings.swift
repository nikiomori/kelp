import Core

/// The shell's own settings: Appearance and General, read where the window, sidebar and inspector draw them.
extension SettingKeys {
    static let theme = Setting("workbench.theme", "auto")
    static let textSize = Setting("workbench.textSize", "normal")
    static let terminalOpacity = Setting("terminal.opacity", "theme")
    static let sideBySideButton = Setting("workbench.sideBySideButton", true)
    static let awakeButton = Setting("workbench.awakeButton", true)
    @MainActor static let iconTheme = Setting("workbench.iconTheme", FileIcon.standard)
    static let language = Setting("workbench.language", "system")

    /// nil: every panel's icon shows.
    static let hiddenPanels = Setting<[String]?>("workbench.inspector.hiddenPanels", nil)
    /// The inspector's icons as they were dragged; panels it doesn't name follow in the registry's order. Not a row.
    static let panelOrder = Setting<[String]>("workbench.inspector.panelOrder", [])
    static let inspectorIconsPosition = Setting("workbench.inspectorIconsPosition", "top")
    static let inspectorIcons = Setting("workbench.inspectorIcons", "center")
    static let inspectorAutoHide = Setting("workbench.inspector.autoHide", false)

    static let sidebarAutoHide = Setting("workbench.sidebar.autoHide", false)
    static let rowHeight = Setting("workbench.sidebar.rowHeight", "system")
    static let agentDetail = Setting("workbench.sidebar.agentDetail", "needsYou")
    static let agentIcons = Setting("workbench.sidebar.agentIcons", "others")
    static let gitBadges = Setting("workbench.sidebar.gitBadges", true)
    static let projectColor = Setting("workbench.sidebar.projectColor", "icon")
    static let serverLook = Setting("workbench.sidebar.serverLook", "stripes")
    static let sidebarOrder = Setting("workbench.sidebar.order", "manual")
}
