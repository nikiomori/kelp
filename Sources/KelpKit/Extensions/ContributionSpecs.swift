// What a contribution is: the IDE's context, a panel, an editor, a command, a setting and its section, an icon theme.
import Agents
import AppKit
import Core
import SwiftUI
import WorkbenchKit

/// What the IDE knows when a contribution runs: the workspace on screen and what has focus.
@MainActor
package struct IDEContext {
    package var workspace: Worktree?
    var project: Repo?
    var focusedFile: String?

    /// What's on screen in `app`.
    static func of(_ app: AppModel) -> IDEContext {
        let worktree = app.worktree(app.workbench.workspaceId)
        return IDEContext(
            workspace: worktree, project: app.repo(worktree?.repoId), focusedFile: app.workbench.focusedFile)
    }
}

/// What the shell may ask a panel for by what it shows, not by whose it is: "show the changes" after a pull, "show
/// the checks" from a row's CI mark. A built-in says which of its panels is which; none, and nothing is shown.
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
    /// What the panel's icon says (nil: nothing). Read under observation, so it must not build the panel.
    var badge: (@MainActor () -> PanelBadge?)?
    /// Keeps `badge` current while the inspector lists the panel (an extension's badge command); cancelled on a rebuild.
    var poll: (@MainActor () async -> Void)?
    let make: @MainActor () -> NSViewController
}

/// A panel icon's mark: a number for what's left to go through (changed files), a dot for something that happened
/// (a failed run). Grey, or red for a failure. A dot goes once its panel has been shown with the same `key`.
package struct PanelBadge: Equatable {
    var count = 0, alert = false
    var key = ""

    /// What an extension's badge command prints (or a page's `kelp.badge`): a number, any other text for a dot (the
    /// text is its key), "!" first for red; nothing or 0: no badge.
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
    /// The tab it opens (nil: none here, as for a workspace that has no changes to review).
    let uri: @MainActor (IDEContext) -> String?
    /// Whether "+" and the empty workspace offer it here (nil: everywhere), as Database only where there is one.
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
    /// The menu bar menu it goes in when Kelp's own layout (`AppDelegate.buildMenu`) doesn't place it; nil: Tools.
    var menu: String?
    /// Whether its menu item can be chosen now (Stop: something runs); nil: always.
    let enabled: (@MainActor () -> Bool)?
    let run: @MainActor ([String: JSONValue]) -> Void
}

/// One setting in Settings and settings.json.
package struct SettingSpec: Codable, Identifiable {
    var key: String
    var title: String
    var type: SettingType
    var `default`: JSONValue?
    /// One line under the title: what the name doesn't say.
    var description: String?
    /// The rest, behind a ⓘ beside the title (and found by search): the description stays a line, not a paragraph.
    var help: String?
    var options: [String]?
    /// What each option is called where it's chosen ("needed" → "When Needed"), said where the setting is declared; an
    /// option not named here shows as its value, capitalized.
    var labels: [String: String]?
    /// How its options show (`SettingLook`); nil: a menu.
    var look: SettingLook?
    /// `[lowest, highest]` a number can be: the stepper stops there, and a value out of it in settings.json counts as the nearest end.
    var range: [Double]?
    /// A heading over this row and the ones after it that share it ("Sidebar"); nil: the section's first, untitled group.
    var group: String?
    /// Left out of the window: it's set on the thing itself (a menu), and stays in settings.json and Quick Open.
    var hidden: Bool?
    /// Shown only while another setting allows it: "key" (on), "key=value" or "key!=value". A row that does nothing until
    /// its parent is on stays out of the way; search still finds it.
    var requires: String?
    /// What an empty text field shows: an example of what goes in it.
    var placeholder: String?
    /// Read for each language's own files, so Settings' language picker shows it; the rest (the font, autosave,
    /// servers) is one value for every file. Limit: said by the row; a setting that starts reading its language says so.
    var perLanguage: Bool?
    /// What the code declaring it knows of its choices (`SettingChoices`); never in a manifest.
    var choices: SettingChoices?
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

/// What a row is. An extension.json names one of the first six; `panels` and `theme` are Kelp's own rows (the
/// inspector's panels, the theme gallery). A name a manifest gives that isn't one of the six reads as `unknown` and shows
/// as a text field, its extension saying why (`problem`).
package enum SettingType: Codable, Equatable {
    case boolean, number, string, `enum`, color, font
    case panels, theme
    case unknown(String)

    private static let named: [String: SettingType] = [
        "boolean": .boolean, "number": .number, "string": .string, "enum": .enum, "color": .color, "font": .font
    ]
    /// As settings.json's schema and the settings guide call it.
    var name: String {
        switch self {
        case .boolean: "boolean"
        case .number: "number"
        case .string: "string"
        case .enum: "enum"
        case .color: "color"
        case .font: "font"
        case .panels: "panels"
        case .theme: "theme"
        case .unknown(let name): name
        }
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

/// How an `enum` row's options show: side by side (two or three short ones), or a drawing each (the shell's, or the
/// setting's own: `SettingChoices.picture`). One a manifest names that Kelp doesn't have reads as `unknown`: a menu.
package enum SettingLook: Codable, Equatable {
    case segments, pictures
    case unknown(String)

    var name: String {
        switch self {
        case .segments: "segments"
        case .pictures: "pictures"
        case .unknown(let name): name
        }
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
    /// What a manifest's row asked for that Kelp doesn't have, said as its extension's error; nil when nothing.
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

/// A setting's choices as only the code that declares it knows them: those there are now (the agents installed), what
/// each is called when that isn't known where it's declared (`SettingSpec.labels` otherwise), and how each is drawn
/// (`look` "pictures"). Asked when shown.
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
        tint: NSColor? = nil,
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
        self.tint = tint
        self.previews = previews
    }
    package let id: String, title: String, icon: String
    var specs: [SettingSpec]
    /// What Settings' search finds a custom page by.
    var keywords: [String]
    /// `custom` is the whole page, as tall as the window, not rows in a form: a list with its details beside it.
    var fillsPane: Bool
    /// Its place in Settings' list; an extension's sections come after Kelp's.
    var order: Int
    /// Its tile's colour in Settings' list, as System Settings colours its panes (nil: grey, as an extension's are).
    var tint: NSColor?
    /// Settings' language picker shows over it: some of its rows are read for each language's own files.
    var perLanguage: Bool { specs.contains { $0.perLanguage == true } }
    /// Rows keep their order; each run of a group under its heading, as System Settings groups its panes.
    var groups: [(String?, [SettingSpec])] {
        specs.filter { $0.hidden != true }.reduce(into: []) { runs, spec in
            if let last = runs.indices.last, runs[last].0 == spec.group {
                runs[last].1.append(spec)
            } else {
                runs.append((spec.group, [spec]))
            }
        }
    }
    /// Sections of its own under the generated rows (accounts, integrations…), or the whole page (`fillsPane`).
    var custom: (@MainActor () -> AnyView)?
    /// Over a group of rows (by its heading; `""` the first, untitled one), what they change, as it is now
    /// (`SettingSamples`).
    var previews: [String: @MainActor () -> AnyView]
}

/// A skill Kelp gives agents, from the built-in whose feature it explains: written as a Claude Code plugin in Kelp's
/// home (`AgentSkills`), which the daemon hands each session it fits.
package struct SkillSpec {
    package init(name: String, description: String, setting: Setting<Bool>? = nil, body: String) {
        self.name = name
        self.description = description
        self.setting = setting
        self.body = body
    }
    /// The plugin's and the skill's name ("kelp-vm"): the daemon picks skills by it.
    let name: String
    /// When an agent should use it: what Claude Code reads to choose it.
    let description: String
    /// Its switch in Settings › Agents; nil: always written (which sessions get it is the daemon's choice).
    let setting: Setting<Bool>?
    /// The skill itself, Markdown.
    let body: String
}

/// A file icon theme in VS Code's format (see IconTheme).
struct IconThemeSpec {
    let id: String, label: String, file: URL
}
