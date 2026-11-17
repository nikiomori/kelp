// The kinds of contribution: the IDE's context, a panel, an editor, a command, a setting and its section, an icon
// theme.
import AppKit
import Core
import SwiftUI

/// What the IDE knows when a contribution runs: the workspace on screen and what has focus.
@MainActor
package struct IDEContext {
    package var workspace: Worktree?
    var project: Repo?
    var focusedFile: String?

    /// Returns the context of what is on screen in `app`.
    static func of(_ app: AppModel) -> IDEContext {
        let worktree = app.worktree(app.workbench.workspaceId)
        return IDEContext(
            workspace: worktree, project: app.repo(worktree?.repoId), focusedFile: app.workbench.focusedFile)
    }
}

/// A role the shell uses to find a panel by what it shows, not by which extension owns it: "show the changes" after a
/// pull, "show the checks" from a row's CI mark. A built-in says which of its panels has which role; when no panel has
/// the role, nothing is shown.
package enum PanelRole: Sendable { case changes, checks }

/// A right-inspector panel.
package struct PanelSpec: Identifiable {
    package init(
        id: String, title: String, icon: String, extensionId: String, role: PanelRole? = nil,
        badge: (@MainActor () -> PanelBadge?)? = nil, poll: (@MainActor () async -> Void)? = nil,
        make: @escaping @MainActor () -> NSViewController
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.icon = icon
        self.extensionId = extensionId
        self.badge = badge
        self.poll = poll
        self.make = make
    }
    package let id: String, title: String, icon: String, extensionId: String
    package let role: PanelRole?
    /// The mark on the panel's icon (nil for none). It is read under observation, so it must not build the panel.
    var badge: (@MainActor () -> PanelBadge?)?
    /// Keeps `badge` current while the inspector lists the panel (an extension's badge command). A rebuild cancels it.
    var poll: (@MainActor () async -> Void)?
    let make: @MainActor () -> NSViewController
}

/// The mark on a panel's icon: a number for what is left to go through (changed files), or a dot for something that
/// happened (a failed run). It is grey, or red for a failure. A dot goes away once its panel has been shown while the
/// dot had the same `key`.
package struct PanelBadge: Equatable {
    var count = 0, alert = false
    var key = ""

    /// Reads what an extension's badge command prints (or what a page passes to `kelp.badge`). A number gives a count,
    /// and any other text gives a dot whose key is that text; a leading "!" makes the badge red. Nothing or 0 gives no
    /// badge.
    package init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        alert = trimmed.hasPrefix("!")
        if alert { trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if let number = Int(trimmed) {
            guard number > 0 else { return nil }
            count = number
        } else {
            guard alert || !trimmed.isEmpty else { return nil }
            key = trimmed
        }
    }
    package init(count: Int = 0, alert: Bool = false, key: String = "") {
        self.count = count
        self.alert = alert
        self.key = key
    }
}

/// An entry of the editor area's "+" menu. `open` runs only when chosen (it may ask questions, start things…).
package struct EditorSpec: Identifiable {
    package init(
        id: String,
        title: String,
        icon: String,
        available: (@MainActor (IDEContext) -> Bool)? = nil,
        uri: @escaping @MainActor (IDEContext) -> String?
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.available = available
        self.uri = uri
    }
    package let id: String, title: String, icon: String
    /// The title as shown: `title` is English data, translated where it appears.
    var label: String { loc(title) }
    /// The URI of the tab the entry opens, or nil when there is none here (as for a workspace that has no changes to
    /// review).
    let uri: @MainActor (IDEContext) -> String?
    /// Whether "+" and the empty workspace offer the entry here (nil means everywhere). Database, for example, is
    /// offered only where there is a database.
    let available: (@MainActor (IDEContext) -> Bool)?

    @MainActor func open(_ ctx: IDEContext, in app: AppModel) {
        if let target = uri(ctx) { app.workbench.open(target) }
    }
}

/// An action with a stable id, the one thing the menu bar, key bindings (settings.json `keys`), the command palette
/// and agents (`kelp run <id>`) call.
package struct CommandSpec: Identifiable {
    package init(
        id: String,
        title: String,
        key: String? = nil,
        menu: String? = nil,
        enabled: (@MainActor () -> Bool)? = nil,
        run: @escaping @MainActor ([String: JSONValue]) -> Void
    ) {
        self.id = id
        self.title = title
        self.key = key
        self.menu = menu
        self.enabled = enabled
        self.run = run
    }
    package let id: String, title: String
    var key: String?
    /// The menu bar menu the command goes in when Kelp's own layout (`AppDelegate.buildMenu`) doesn't place it; nil
    /// means Tools.
    var menu: String?
    /// Whether the command's menu item can be chosen now (Stop only while something runs); nil means always.
    let enabled: (@MainActor () -> Bool)?
    let run: @MainActor ([String: JSONValue]) -> Void
}

/// One setting in Settings and settings.json.
package struct SettingSpec: Codable, Identifiable {
    var key: String
    var title: String
    var type: SettingType
    var `default`: JSONValue?
    /// One line on what the name doesn't say. It sits behind the ⓘ beside the title when there's no `help`, so each row
    /// stays one line.
    var description: String?
    /// A longer explanation, behind the ⓘ in place of the description (search finds it too).
    var help: String?
    var options: [String]?
    /// The name each option shows where it's chosen ("needed" → "When Needed"), given where the setting is declared.
    /// An option not named here shows as its value, capitalized.
    var labels: [String: String]?
    /// How the options show (`SettingLook`); nil means a menu.
    var look: SettingLook?
    /// The `[lowest, highest]` a number can be. The stepper stops at these, and a value outside them in settings.json
    /// counts as the nearest end.
    var range: [Double]?
    /// A heading over this row and the rows after it that share it ("Sidebar"); nil puts the row in the section's
    /// first, untitled group.
    var group: String?
    /// Whether the row is left out of the Settings window, because it's set on the thing itself (a menu). It stays in
    /// settings.json and Quick Open.
    var hidden: Bool?
    /// The row shows only while another setting allows it: "key" (on), "key=value" or "key!=value". A row that does
    /// nothing until its parent is on stays out of the way, but search still finds it.
    var requires: String?
    /// What an empty text field shows, as an example of what goes in it.
    var placeholder: String?
    /// Whether the setting is read for each language's own files, so Settings' language picker shows it. Other settings
    /// (the font, autosave, servers) have one value for every file. Limit: said by the row; a setting that starts
    /// reading its language says so.
    var perLanguage: Bool?
    /// What the code that declares the setting knows about its choices (`SettingChoices`). A manifest never sets it.
    var choices: SettingChoices?
    /// A tile before the title, used only where a card's rows are about different things (General, the alerts, the
    /// skills). A manifest never sets it. Orange and red are only for "asks" and "failed", as everywhere in Kelp.
    var icon: (symbol: String, tint: NSColor)?
    package var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, title, type, `default`, description, help, options, labels, look, range, group, hidden, requires
        case placeholder, perLanguage
    }

    var bounds: ClosedRange<Double>? {
        guard let range, range.count == 2, range[0] <= range[1] else { return nil }
        return range[0]...range[1]
    }
    func clamped(_ v: Double) -> Double { bounds.map { min(max(v, $0.lowerBound), $0.upperBound) } ?? v }
}

/// The kind of a settings row. An extension.json names one of the first six; `panels` and `theme` are Kelp's own rows
/// (the inspector's panels, the theme gallery). A name in a manifest that isn't one of the six reads as `unknown` and
/// shows as a text field, and the extension's error says why (`problem`).
package enum SettingType: Codable, Equatable {
    case boolean, number, string, `enum`, color, font
    case panels, theme
    case unknown(String)

    private static let named: [String: SettingType] = [
        "boolean": .boolean, "number": .number, "string": .string, "enum": .enum, "color": .color, "font": .font
    ]
    /// The type's name as settings.json's schema and the settings guide write it.
    var name: String {
        if case .unknown(let name) = self { return name }
        return "\(self)"   // each case is named as it's written
    }
    package init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        self = Self.named[name] ?? .unknown(name)
    }
    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }
}

/// How an `enum` row's options are shown: side by side (for two or three short ones), or each as a drawing (the
/// shell's drawing, or the setting's own from `SettingChoices.picture`). A look a manifest names that Kelp doesn't have
/// reads as `unknown` and shows as a menu.
package enum SettingLook: Codable, Equatable {
    case segments, pictures
    case unknown(String)

    var name: String {
        if case .unknown(let name) = self { return name }
        return "\(self)"
    }
    package init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        self = ["segments": .segments, "pictures": .pictures][name] ?? .unknown(name)
    }
    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }
}

extension SettingSpec {
    /// What a manifest's row asked for that Kelp doesn't have, reported as the extension's error; nil when there is
    /// nothing.
    var problem: String? {
        if case .unknown(let name) = type {
            return String(localized: "Setting “\(key)”: Kelp has no type “\(name)”, so it shows as a text field.")
        }
        if case .unknown(let name)? = look {
            return String(localized: "Setting “\(key)”: Kelp has no look “\(name)”, so it shows as a menu.")
        }
        return nil
    }
}

/// A setting's choices as only the code that declares the setting knows them: the choices there are now (the agents
/// installed), what each is called when that isn't known where it's declared (otherwise `SettingSpec.labels`), and how
/// each is drawn (`look` "pictures"). They are asked for when shown.
package struct SettingChoices {
    package init(
        options: (@MainActor () -> [String])? = nil, name: (@MainActor (_ option: String) -> String)? = nil,
        picture: (@MainActor (_ option: String) -> AnyView)? = nil
    ) {
        self.options = options
        self.name = name
        self.picture = picture
    }
    let options: (@MainActor () -> [String])?
    let name: (@MainActor (_ option: String) -> String)?
    let picture: (@MainActor (_ option: String) -> AnyView)?
}

package struct SettingsSection: Identifiable {
    package init(
        id: String,
        title: String,
        icon: String,
        specs: [SettingSpec],
        custom: (@MainActor () -> AnyView)? = nil,
        keywords: [String] = [],
        fillsPane: Bool = false,
        order: Int = 100,
        previews: [String: @MainActor () -> AnyView] = [:]
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.specs = specs
        self.custom = custom
        self.keywords = keywords
        self.fillsPane = fillsPane
        self.order = order
        self.previews = previews
    }
    package let id: String, title: String, icon: String
    var specs: [SettingSpec]
    /// What Settings' search finds a custom page by.
    var keywords: [String]
    /// Whether `custom` is the whole page, as tall as the window, rather than rows in a form (a list with its details
    /// beside it).
    var fillsPane: Bool
    /// The section's place in Settings' list; an extension's sections come after Kelp's.
    var order: Int
    /// Whether Settings shows its language picker over the section, because some of its rows are read for each
    /// language's own files.
    var perLanguage: Bool { specs.contains { $0.perLanguage == true } }
    /// The shown rows under their headings. Rows keep their order, and each run of rows in one group goes under the
    /// group's heading, as System Settings groups its panes.
    var groups: [(String?, [SettingSpec])] {
        specs.filter { $0.hidden != true }.reduce(into: []) { runs, spec in
            if let last = runs.indices.last, runs[last].0 == spec.group {
                runs[last].1.append(spec)
            } else {
                runs.append((spec.group, [spec]))
            }
        }
    }
    /// The section's own views under the generated rows (accounts, integrations…), or the whole page (`fillsPane`).
    var custom: (@MainActor () -> AnyView)?
    /// Previews shown over a group of rows, keyed by the group's heading (`""` for the first, untitled group). Each
    /// shows what the rows change, as it is now (`SettingSamples`).
    var previews: [String: @MainActor () -> AnyView]
}

/// A skill Kelp gives agents, from the built-in whose feature the skill explains. It is written as a Claude Code plugin
/// in Kelp's home (`AgentSkills`), and the daemon hands it to each session it fits.
package struct SkillSpec {
    package init(name: String, description: String, setting: Setting<Bool>? = nil, body: String) {
        self.name = name
        self.description = description
        self.setting = setting
        self.body = body
    }
    /// The name of the plugin and of its skill ("kelp-vm"); the daemon picks skills by this name.
    let name: String
    /// When an agent should use the skill; Claude Code reads this to choose it.
    let description: String
    /// The skill's switch in Settings › Agents. With nil the skill is always written (the daemon chooses which sessions
    /// get it).
    let setting: Setting<Bool>?
    /// The skill itself, Markdown.
    let body: String
}

/// A file icon theme in VS Code's format (see IconTheme).
struct IconThemeSpec {
    let id: String, label: String, file: URL
}
