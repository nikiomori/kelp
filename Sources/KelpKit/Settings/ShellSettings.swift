import Core

/// The shell's own settings: Appearance and General, read where the window, sidebar and inspector draw them. Their rows
/// in Settings follow, below.
extension SettingKeys {
    static let theme = Setting("workbench.theme", "auto")
    static let textSize = Setting("workbench.textSize", "normal")
    static let terminalOpacity = Setting("terminal.opacity", "theme")
    /// "regular", "compact", or "auto" (compact once the tabs no longer fit).
    static let tabWidth = Setting("workbench.tabWidth", "auto")
    /// "regular" (28 pt tabs in a 40 pt strip) or "compact" (24 in 32); the sidebar's and inspector's band follows.
    static let tabHeight = Setting("workbench.tabHeight", "regular")
    static let sideBySideButton = Setting("workbench.sideBySideButton", true)
    static let awakeButton = Setting("workbench.awakeButton", true)
    @MainActor static let iconTheme = Setting("workbench.iconTheme", FileIcon.standard)
    static let language = Setting("workbench.language", "system")
    static let confirmQuit = Setting("workbench.confirmQuit", false)
    /// Keyboard shortcuts set by hand, command id → key ("" none): Settings › Keyboard, its own page. Not a row.
    static let keys = Setting<JSONValue?>("keys", nil)

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
    static let projectColor = Setting("workbench.sidebar.projectColor", "icon")
    static let serverLook = Setting("workbench.sidebar.serverLook", "stripes")
    static let sidebarOrder = Setting("workbench.sidebar.order", "manual")
}

/// The shell's rows in Settings, beside its keys: what each is called, its choices and its help.
extension Builtins {
    /// Appearance: the theme and text first, then how the sidebar, the inspector and the window look.
    static func appearanceRows(_ app: AppModel) -> [SettingSpec] {
        [
            s(
                SettingKeys.theme, "Color theme", .theme,
                "The window, terminal and editor together.",
                help:
                    "The window, terminal and editor together. Match System switches Kelp Light / Dark with macOS; Ghostty keeps your Ghostty terminal colors.",
                choices: SettingChoices(
                    options: { ["auto", "ghostty"] + app.themes.themes.map(\.id) },
                    name: { value in
                        value == "auto"
                            ? String(localized: "Match System")
                            : value == "ghostty"
                                ? String(localized: "Ghostty config")
                                : app.themes.themes.first { $0.id == value }?.name ?? value
                    })),
            s(
                SettingKeys.textSize, "Text size", .enum,
                "Everything but code.",
                help:
                    "Everything but code: sidebar, inspector, tabs, bars and popovers. The terminal and the editor have their own font sizes.",
                options: ["normal", "large", "larger"], look: .pictures),
            s(
                SettingKeys.tabWidth, "Tab width", .enum,
                "Compact keeps six letters of a title, so more agents fit in a pane.",
                help:
                    "Compact keeps six letters of a title, so more agents fit in a pane. Automatic stays Regular "
                    + "while the tabs fit and turns Compact when they don't. Also in a tab's right-click menu.",
                options: ["auto", "regular", "compact"], labels: ["auto": String(localized: "Automatic")],
                look: .pictures),
            s(
                SettingKeys.tabHeight, "Tab height", .enum,
                "Compact gives a pane 8 pt more room under its tabs.",
                help: "Compact tabs are 24 pt in a 32 pt strip. Also in a tab's right-click menu.",
                options: ["regular", "compact"], look: .pictures),
            s(
                SettingKeys.terminalOpacity, "Terminal opacity", .enum,
                "The desktop shows through the terminals, in any theme.",
                help:
                    "Under 100% the desktop shows through the terminals, and through the window around them, in any theme.",
                options: ["theme", "100", "90", "80", "70", "60", "50", "40"],
                labels: Dictionary(
                    uniqueKeysWithValues: ["100", "90", "80", "70", "60", "50", "40"].map {
                        ($0, "\($0)%")
                    }
                ).merging(["theme": String(localized: "From Theme")]) { $1 })
        ] + sidebarRows + inspectorRows + [
            s(
                SettingKeys.sideBySideButton, "Agents side by side button", .boolean,
                "In the title bar, with two agents or more; ⌃⌘T works either way.",
                help:
                    "In the title bar, right of the search, with two agents or more; right-click it to hide it. ⌃⌘T works either way.",
                group: "Window"),
            s(
                SettingKeys.awakeButton, "Keep Mac awake button", .boolean,
                "A cup in the title bar while the Mac is kept awake.",
                help:
                    "A cup in the title bar while the Mac is kept awake; right-click it to hide it. Tools › Keep Mac Awake works either way.",
                group: "Window"),
            s(
                SettingKeys.iconTheme, "File icon theme", .enum,
                "Icons in Files, Source Control and tabs.",
                help:
                    "Icons in Files, Source Control and tabs. VS Code icon themes work as they are: Settings › Extensions › Install…",
                group: "Window",
                choices: SettingChoices(
                    options: { app.fileIcons.themes.map(\.id) },
                    name: { value in app.fileIcons.themes.first { $0.id == value }?.label ?? value }))
        ]
    }

    static let generalRows = [
        s(
            SettingKeys.language, "Language", .enum, "Takes effect the next time Kelp opens.",
            // Each language in its own words, so it can be found whichever language Kelp is in.
            options: ["system", "en", "ru"],
            labels: ["system": String(localized: "Match System"), "en": "English", "ru": "Русский"]),
        s(
            SettingKeys.confirmQuit, "Ask before quitting", .boolean,
            "⌘Q and closing the window ask “Quit Kelp?” first.")
    ]

    /// Appearance › Inspector: its panels and where their icons sit, here and in the icons' own right-click menu.
    static let inspectorRows = [
        s(
            SettingKeys.hiddenPanels, "Panels", .panels, "Drag an icon in the inspector to move it.",
            group: "Inspector"),
        s(
            SettingKeys.inspectorIconsPosition, "Panel icons", .enum, options: ["top", "bottom"],
            labels: ["top": String(localized: "Beside the Tabs"), "bottom": String(localized: "Under the Panel")],
            look: .segments, group: "Inspector"),
        s(
            SettingKeys.inspectorIcons, "Icon alignment", .enum, options: ["left", "center", "right"],
            look: .segments, group: "Inspector"),
        s(
            SettingKeys.inspectorAutoHide, "Auto-hide inspector", .boolean,
            "Comes in while the pointer is at the window's right edge.",
            group: "Inspector")
    ]

    /// Appearance › Sidebar: what people see differently in the list, each read where the sidebar draws it.
    static let sidebarRows = [
        s(
            SettingKeys.sidebarAutoHide, "Auto-hide sidebar", .boolean,
            "Comes in while the pointer is at the window's left edge, like the Dock.",
            group: "Sidebar"),
        s(
            SettingKeys.rowHeight, "Row height", .enum,
            nil,
            help: "Match System follows Sidebar icon size in System Settings › Appearance.",
            options: ["system", "compact", "regular", "large"], labels: ["system": String(localized: "Match System")],
            look: .pictures, group: "Sidebar"),
        s(
            SettingKeys.agentDetail, "Show what an agent asks", .enum,
            "A second line under an agent: its question, or what went wrong.",
            options: ["needsYou", "always", "never"], labels: ["needsYou": String(localized: "When They Need You")],
            look: .pictures, group: "Sidebar"),
        s(
            SettingKeys.agentIcons, "Agent icons", .enum,
            "Other Agents Only hides the default agent's icon.",
            options: ["others", "always", "never"], labels: ["others": String(localized: "Other Agents Only")],
            group: "Sidebar"),
        s(
            SettingKeys.gitBadges, "Changes and pull requests", .boolean,
            "“+6 −2” and “#128” beside folders.",
            help: "“+6 −2” and “#128” beside folders. Off also stops checking GitHub for them.", group: "Sidebar"),
        s(
            SettingKeys.projectColor, "Project color", .enum,
            nil,
            help:
                "How the color from a project's row menu shows. On the icon it also follows the project to the title bar, ⌃Tab and Needs You.",
            options: ["icon", "card"],
            labels: ["icon": String(localized: "On the Icon"), "card": String(localized: "Filled Card")],
            look: .pictures, group: "Sidebar"),
        s(
            SettingKeys.serverLook, "Servers", .enum,
            nil, help: "How a server's card shows that its projects run on another machine.",
            options: ["stripes", "sparse", "fade", "icon"],
            labels: [
                "stripes": String(localized: "Stripes"), "sparse": String(localized: "Sparse Stripes"),
                "fade": String(localized: "Stripes by the Icon"), "icon": String(localized: "Under the Icon")
            ], look: .pictures, group: "Sidebar"),
        s(
            SettingKeys.sidebarOrder, "Project order", .enum,
            "Agents First moves rows as agents start and stop.",
            options: ["manual", "active"],
            labels: ["manual": String(localized: "As You Arrange Them"), "active": String(localized: "Agents First")],
            look: .segments, group: "Sidebar")
    ]
}
