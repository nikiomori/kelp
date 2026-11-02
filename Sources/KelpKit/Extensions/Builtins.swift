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

    package static func s(_ key: String, _ title: String, _ type: String, _ def: JSONValue?, _ desc: String? = nil, options: [String]? = nil,
                          range: [Double]? = nil, group: String? = nil, hidden: Bool? = nil) -> SettingSpec {
        SettingSpec(key: key, title: title, type: type, default: def, description: desc, options: options, range: range, group: group, hidden: hidden)
    }

    package static let appearance = Builtin("kelp.appearance", "Appearance", "Themes for the window, terminal and editor.",
                                            icon: "paintpalette", essential: true) { _ in
        var c = Contributions()
        c.settings = [SettingsSection(id: "appearance", title: "Appearance", icon: "paintpalette", specs: [
            s("workbench.language", "Language", "enum", "system", "Takes effect the next time Kelp opens.",
              options: ["system", "en", "ru"]),
            s("workbench.theme", "Color theme", "theme", "auto",
              "The window, terminal and editor together. Match System switches Kelp Light / Dark with macOS; Ghostty keeps your Ghostty terminal colors."),
            s("workbench.textSize", "Text size", "enum", "normal",
              "Everything but code: sidebar, inspector, tabs, bars and popovers. The terminal and the editor have their own font sizes.",
              options: ["normal", "large", "larger"]),
            s("terminal.opacity", "Terminal opacity", "enum", "theme",
              "Under 100% the desktop shows through the terminals, and through the window around them, in any theme.",
              options: ["theme", "100", "90", "80", "70", "60", "50", "40"]),
            s("workbench.iconTheme", "File icon theme", "enum", .string(FileIcon.standard),
              "Icons in Files, Source Control and tabs. VS Code icon themes work as they are: Settings › Extensions › Install…")
        ], order: 10), SettingsSection(id: "window", title: "Window", icon: "macwindow", specs: [
            s("workbench.sideBySideButton", "Agents side by side button", "boolean", true,
              "In the title bar, right of the search; right-click it to hide it. ⌃⌘T works either way."),
            s("agents.dockIcon", "Dock icon", "enum", "agents", "What Kelp's icon in the Dock shows. Also in its menu, on a right-click.",
              options: ["agents", "usage", "icon"])
        ] + sidebar + inspector, order: 20), SettingsSection(id: "keyboard", title: "Keyboard", icon: "keyboard", specs: [],
                                                             custom: { AnyView(KeyboardSettings()) }, order: 95)]
        return c
    }

    /// Window › Inspector. Where the icons sit is set on the icons, in their menu.
    private static let inspector = [
        s("workbench.inspector.autoHide", "Auto-hide inspector", "boolean", false, "Comes in while the pointer is at the window's right edge.",
          group: "Inspector"),
        s("workbench.inspectorIcons", "Inspector icons", "enum", "center", "Where the panel icons sit in their row.",
          options: ["left", "center", "right"], group: "Inspector", hidden: true),
        s("workbench.inspectorIconsPosition", "Inspector icons position", "enum", "top",
          "Level with the tabs or under the panel. Drag an icon to move it; right-click the icons to hide them.",
          options: ["top", "bottom"], group: "Inspector", hidden: true)
    ]

    /// Window › Sidebar: what people see differently in the list, each read where the sidebar draws it.
    private static let sidebar = [
        s("workbench.sidebar.autoHide", "Auto-hide sidebar", "boolean", false, "Comes in while the pointer is at the window's left edge, like the Dock.",
          group: "Sidebar"),
        s("workbench.sidebar.rowHeight", "Row height", "enum", "system",
          "Match System follows Sidebar icon size in System Settings › Appearance.", options: ["system", "compact", "regular", "large"], group: "Sidebar"),
        s("workbench.sidebar.agentDetail", "Show what an agent asks", "enum", "needsYou",
          "A second line under an agent: its question, or what went wrong.", options: ["needsYou", "always", "never"], group: "Sidebar"),
        s("workbench.sidebar.agentIcons", "Agent icons", "enum", "always", "Other Agents Only hides the default agent's icon.",
          options: ["others", "always", "never"], group: "Sidebar"),
        s("workbench.sidebar.gitBadges", "Changes and pull requests", "boolean", true,
          "“+6 −2” and “#128” beside folders. Off also stops checking GitHub for them.", group: "Sidebar"),
        s("workbench.sidebar.projectColor", "Project color", "enum", "icon",
          "How the color from a project's row menu shows. On the icon it also follows the project to the title bar, ⌃Tab and Needs You.",
          options: ["icon", "card"], group: "Sidebar"),
        s("workbench.sidebar.order", "Project order", "enum", "manual", "Agents First moves rows as agents start and stop.",
          options: ["manual", "active"], group: "Sidebar")
    ]
}
