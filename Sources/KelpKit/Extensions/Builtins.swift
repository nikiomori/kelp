import Agents
import AppKit
import Core
import DesignKit
import SwiftUI
import WorkbenchKit

/// A built-in extension: same contribution points as an extension.json folder, implemented in Swift.
@MainActor
package struct Builtin {
    let info: ExtensionInfo
    /// What it adds to `app`: its tabs, panels and commands are made with it.
    let contribute: @MainActor (_ app: AppModel) -> Contributions

    /// Off on a clean install: Settings › Extensions turns it on (once settings.json has its own list, that list decides).
    let offByDefault: Bool

    package init(
        _ id: String, _ name: String, _ description: String, icon: String, essential: Bool = false,
        offByDefault: Bool = false,
        _ contribute: @escaping @MainActor (_ app: AppModel) -> Contributions
    ) {
        info = ExtensionInfo(
            id: id, name: name, description: description, version: "built-in", icon: icon, builtin: true,
            essential: essential, enabled: true)
        self.offByDefault = offByDefault
        self.contribute = contribute
    }
}

@MainActor
package enum Builtins {
    /// A command that takes no arguments.
    package static func cmd(_ id: String, _ title: String, _ key: String? = nil, _ run: @escaping @MainActor () -> Void)
        -> CommandSpec
    {
        CommandSpec(id: id, title: title, key: key) { _ in run() }
    }
    /// The editor area on screen; a beep when there is none.
    static func editor(_ app: AppModel) -> EditorArea? {
        if app.workbench.editor == nil { NSSound.beep() }
        return app.workbench.editor
    }

    /// A row in Settings for a declared setting: its key and default are the declaration's.
    package static func s<Value>(
        _ setting: Setting<Value>, _ title: String, _ type: SettingType, _ desc: String? = nil, help: String? = nil,
        options: [String]? = nil, labels: [String: String]? = nil, look: SettingLook? = nil, range: [Double]? = nil,
        group: String? = nil, hidden: Bool? = nil, requires: String? = nil, placeholder: String? = nil,
        perLanguage: Bool? = nil, choices: SettingChoices? = nil, icon: (symbol: String, tint: NSColor)? = nil
    ) -> SettingSpec {
        SettingSpec(
            key: setting.key, title: title, type: type, default: setting.fallback.setting, description: desc,
            help: help, options: options, labels: labels, look: look, range: range, group: group, hidden: hidden,
            requires: requires, placeholder: placeholder, perLanguage: perLanguage, choices: choices,
            icon: icon)
    }

    package static let appearance = Builtin(
        "kelp.appearance", "Appearance", "Themes for the window, terminal and editor.",
        icon: "paintpalette", essential: true
    ) { app in
        var contributions = Contributions()
        // Everything you see in one place (`appearanceRows`). General has what's about the app itself: its language,
        // updates, the background service. The rows are beside their keys, in ShellSettings.swift.
        contributions.settings = [
            SettingsSection(
                id: "appearance", title: "Appearance", icon: "paintpalette",
                specs: appearanceRows(app), order: 10),
            SettingsSection(
                id: "general", title: "General", icon: "gearshape",
                specs: generalRows, custom: { AnyView(GeneralSettings()) },
                keywords: ["Updates", "Background", "Login Items"], order: 5),
            SettingsSection(
                id: "keyboard", title: "Keyboard", icon: "command", specs: [],
                custom: { AnyView(KeyboardSettings()) }, order: 95)
        ]
        return contributions
    }
}
