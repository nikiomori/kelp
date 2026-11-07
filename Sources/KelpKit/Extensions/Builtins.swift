import AppKit
import SwiftUI
import Core
import Agents
import WorkbenchKit

/// A built-in extension: same contribution points as an extension.json folder, implemented in Swift.
@MainActor
package struct Builtin {
    let info: ExtensionInfo
    /// What it adds to `app`: its tabs, panels and commands are made with it.
    let contribute: @MainActor (_ app: AppModel) -> Contributions

    package init(_ id: String, _ name: String, _ description: String, icon: String, essential: Bool = false,
                 _ contribute: @escaping @MainActor (_ app: AppModel) -> Contributions) {
        info = ExtensionInfo(id: id, name: name, description: description, version: "built-in", icon: icon, builtin: true, essential: essential, enabled: true)
        self.contribute = contribute
    }
}

@MainActor
package enum Builtins {
    /// A command that takes no arguments.
    package static func cmd(_ id: String, _ title: String, _ key: String? = nil, _ run: @escaping @MainActor () -> Void) -> CommandSpec {
        CommandSpec(id: id, title: title, key: key) { _ in run() }
    }
    /// The editor area on screen; a beep when there is none.
    package static func editor(_ app: AppModel) -> EditorArea? {
        if app.workbench.editor == nil { NSSound.beep() }
        return app.workbench.editor
    }

    package static func s(_ key: String, _ title: String, _ type: String, _ def: JSONValue?, _ desc: String? = nil, help: String? = nil,
                          options: [String]? = nil, range: [Double]? = nil, group: String? = nil, hidden: Bool? = nil,
                          requires: String? = nil, placeholder: String? = nil) -> SettingSpec {
        SettingSpec(key: key, title: title, type: type, default: def, description: desc, help: help, options: options, range: range, group: group,
                    hidden: hidden, requires: requires, placeholder: placeholder)
    }

    package static let appearance = Builtin("kelp.appearance", "Appearance", "Themes for the window, terminal and editor.",
                                            icon: "paintpalette", essential: true) { _ in
        var c = Contributions()
        // Everything you see in one place: the theme and text first, then how the sidebar, the inspector and the window
        // look. General has what's about the app itself: its language, updates, the background service.
        c.settings = [SettingsSection(id: "appearance", title: "Appearance", icon: "paintpalette", specs: [
            s("workbench.theme", "Color theme", "theme", "auto",
              "The window, terminal and editor together.",
              help: "The window, terminal and editor together. Match System switches Kelp Light / Dark with macOS; Ghostty keeps your Ghostty terminal colors."),
            s("workbench.textSize", "Text size", "enum", "normal",
              "Everything but code.",
              help: "Everything but code: sidebar, inspector, tabs, bars and popovers. The terminal and the editor have their own font sizes.",
              options: ["normal", "large", "larger"]),
            s("terminal.opacity", "Terminal opacity", "enum", "theme",
              "The desktop shows through the terminals, in any theme.",
              help: "Under 100% the desktop shows through the terminals, and through the window around them, in any theme.",
              options: ["theme", "100", "90", "80", "70", "60", "50", "40"])
        ] + sidebar + inspector + [
            s("workbench.sideBySideButton", "Agents side by side button", "boolean", true,
              "In the title bar, with two agents or more; ⌃⌘T works either way.",
              help: "In the title bar, right of the search, with two agents or more; right-click it to hide it. ⌃⌘T works either way.", group: "Window"),
            s("workbench.awakeButton", "Keep Mac awake button", "boolean", true,
              "A cup in the title bar while the Mac is kept awake.",
              help: "A cup in the title bar while the Mac is kept awake; right-click it to hide it. Tools › Keep Mac Awake works either way.", group: "Window"),
            s("workbench.iconTheme", "File icon theme", "enum", .string(FileIcon.standard),
              "Icons in Files, Source Control and tabs.",
              help: "Icons in Files, Source Control and tabs. VS Code icon themes work as they are: Settings › Extensions › Install…", group: "Window")
        ], order: 10), SettingsSection(id: "general", title: "General", icon: "gearshape", specs: [
            s("workbench.language", "Language", "enum", "system", "Takes effect the next time Kelp opens.", options: ["system", "en", "ru"])
        ], custom: { AnyView(GeneralSettings()) }, keywords: ["Updates", "Background", "Login Items"], order: 5),
                      SettingsSection(id: "keyboard", title: "Keyboard", icon: "keyboard", specs: [],
                                      custom: { AnyView(KeyboardSettings()) }, order: 95)]
        return c
    }

    /// Appearance › Inspector: its panels and where their icons sit, here and in the icons' own right-click menu.
    private static let inspector = [
        s("workbench.inspector.hiddenPanels", "Panels", "panels", nil, "Drag an icon in the inspector to move it.", group: "Inspector"),
        s("workbench.inspectorIconsPosition", "Panel icons", "enum", "top", options: ["top", "bottom"], group: "Inspector"),
        s("workbench.inspectorIcons", "Icon alignment", "enum", "center", options: ["left", "center", "right"], group: "Inspector"),
        s("workbench.inspector.autoHide", "Auto-hide inspector", "boolean", false, "Comes in while the pointer is at the window's right edge.",
          group: "Inspector")
    ]

    /// Appearance › Sidebar: what people see differently in the list, each read where the sidebar draws it.
    private static let sidebar = [
        s("workbench.sidebar.autoHide", "Auto-hide sidebar", "boolean", false, "Comes in while the pointer is at the window's left edge, like the Dock.",
          group: "Sidebar"),
        s("workbench.sidebar.rowHeight", "Row height", "enum", "system",
          nil,
          help: "Match System follows Sidebar icon size in System Settings › Appearance.",
          options: ["system", "compact", "regular", "large"], group: "Sidebar"),
        s("workbench.sidebar.agentDetail", "Show what an agent asks", "enum", "needsYou",
          "A second line under an agent: its question, or what went wrong.", options: ["needsYou", "always", "never"], group: "Sidebar"),
        s("workbench.sidebar.agentIcons", "Agent icons", "enum", "others", "Other Agents Only hides the default agent's icon.",
          options: ["others", "always", "never"], group: "Sidebar"),
        s("workbench.sidebar.gitBadges", "Changes and pull requests", "boolean", true,
          "“+6 −2” and “#128” beside folders.",
          help: "“+6 −2” and “#128” beside folders. Off also stops checking GitHub for them.", group: "Sidebar"),
        s("workbench.sidebar.projectColor", "Project color", "enum", "icon",
          nil, help: "How the color from a project's row menu shows. On the icon it also follows the project to the title bar, ⌃Tab and Needs You.",
          options: ["icon", "card"], group: "Sidebar"),
        s("workbench.sidebar.serverLook", "Servers", "enum", "stripes",
          nil, help: "How a server's card shows that its projects run on another machine.",
          options: ["stripes", "sparse", "fade", "icon"], group: "Sidebar"),
        s("workbench.sidebar.order", "Project order", "enum", "manual", "Agents First moves rows as agents start and stop.",
          options: ["manual", "active"], group: "Sidebar")
    ]
}
