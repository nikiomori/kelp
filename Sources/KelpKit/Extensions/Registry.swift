import AppKit
import SwiftUI
import Core
import Agents
import WorkbenchKit

/// What the IDE knows when a contribution runs: the workspace on screen and what has focus.
@MainActor
package struct IDEContext {
    package var workspace: Worktree?
    var project: Repo?
    var focusedFile: String?

    /// What's on screen in `app`.
    package static func of(_ app: AppModel) -> IDEContext {
        let w = app.worktree(app.workbench.workspaceId)
        return IDEContext(workspace: w, project: app.repo(w?.repoId), focusedFile: app.workbench.focusedFile)
    }
}

/// A right-inspector panel.
package struct PanelSpec: Identifiable {
    package init(id: String, title: String, icon: String, extensionId: String,
                 badge: (@MainActor () -> PanelBadge?)? = nil, poll: (@MainActor () async -> Void)? = nil,
                 make: @escaping @MainActor () -> NSViewController) {
        self.id = id
        self.title = title
        self.icon = icon
        self.extensionId = extensionId
        self.badge = badge
        self.poll = poll
        self.make = make
    }
    package let id: String, title: String, icon: String, extensionId: String
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
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        alert = t.hasPrefix("!")
        if alert { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if let n = Int(t) {
            guard n > 0 else { return nil }
            count = n
        } else {
            guard alert || !t.isEmpty else { return nil }
            key = t
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
    package init(id: String,
                 title: String,
                 icon: String,
                 uri: @escaping @MainActor (IDEContext) -> String?) {
        self.id = id
        self.title = title
        self.icon = icon
        self.uri = uri
    }
    package let id: String, title: String, icon: String
    /// The title as shown: `title` is English data, translated where it appears.
    var label: String { loc(title) }
    /// The tab it opens (nil: none here, as for a workspace that has no changes to review).
    let uri: @MainActor (IDEContext) -> String?

    @MainActor package func open(_ ctx: IDEContext, in app: AppModel) { if let u = uri(ctx) { app.workbench.open(u) } }
}

/// An action with a stable id, the one thing the menu bar, key bindings (settings.json `keys`), the command palette
/// and agents (`kelp run <id>`) call.
package struct CommandSpec: Identifiable {
    package init(id: String,
                 title: String,
                 key: String? = nil,
                 menu: String? = nil,
                 run: @escaping @MainActor ([String: JSONValue]) -> Void) {
        self.id = id
        self.title = title
        self.key = key
        self.menu = menu
        self.run = run
    }
    package let id: String, title: String
    package var key: String?
    /// The menu bar menu it goes in when Kelp's own layout (`AppDelegate.buildMenu`) doesn't place it; nil: Tools.
    var menu: String?
    package let run: @MainActor ([String: JSONValue]) -> Void
}

/// One setting in Settings and settings.json.
package struct SettingSpec: Codable, Identifiable {
    var key: String
    var title: String
    var type: String            // boolean · number · string · enum · color · font
    var `default`: JSONValue?
    /// One line under the title: what the name doesn't say.
    var description: String?
    /// The rest, behind a ⓘ beside the title (and found by search): the description stays a line, not a paragraph.
    var help: String?
    var options: [String]?
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
    package var id: String { key }

    var bounds: ClosedRange<Double>? {
        guard let range, range.count == 2, range[0] <= range[1] else { return nil }
        return range[0]...range[1]
    }
    func clamped(_ v: Double) -> Double { bounds.map { min(max(v, $0.lowerBound), $0.upperBound) } ?? v }
}

package struct SettingsSection: Identifiable {
    package init(id: String,
                 title: String,
                 icon: String,
                 specs: [SettingSpec],
                 custom: (@MainActor () -> AnyView)? = nil,
                 keywords: [String] = [],
                 fillsPane: Bool = false,
                 order: Int = 100) {
        self.id = id
        self.title = title
        self.icon = icon
        self.specs = specs
        self.custom = custom
        self.keywords = keywords
        self.fillsPane = fillsPane
        self.order = order
    }
    package let id: String, title: String, icon: String
    var specs: [SettingSpec]
    /// What Settings' search finds a custom page by.
    var keywords: [String]
    /// `custom` is the whole page, as tall as the window, not rows in a form: a list with its details beside it.
    var fillsPane: Bool
    /// Its place in Settings' list; an extension's sections come after Kelp's.
    var order: Int
    /// Rows keep their order; each run of a group under its heading, as System Settings groups its panes.
    var groups: [(String?, [SettingSpec])] {
        specs.filter { $0.hidden != true }.reduce(into: []) { g, s in
            if let last = g.indices.last, g[last].0 == s.group { g[last].1.append(s) } else { g.append((s.group, [s])) }
        }
    }
    /// Sections of its own under the generated rows (accounts, integrations…), or the whole page (`fillsPane`).
    var custom: (@MainActor () -> AnyView)?
}

/// A file icon theme in VS Code's format (see IconTheme).
struct IconThemeSpec {
    let id: String, label: String, file: URL
}

/// Opens tabs for URIs of a scheme ("session", "file", "https"…).
package struct TabProvider {
    package init(schemes: [String], make: @escaping @MainActor (String) -> TabContent?,
                 closeUnbuilt: (@MainActor (_ uri: String) async -> Bool)? = nil,
                 menu: (@MainActor (_ menu: NSMenu, _ uri: String, _ workspace: String, _ openBeside: @escaping @MainActor (String) -> Void) -> Void)? = nil,
                 browse: (@MainActor (_ tab: TabContent, _ action: String, _ args: JSONValue) async throws -> JSONValue)? = nil) {
        self.schemes = schemes
        self.make = make
        self.closeUnbuilt = closeUnbuilt
        self.menu = menu
        self.browse = browse
    }
    let schemes: [String]
    let make: @MainActor (String) -> TabContent?
    /// Closing a tab of its URI that was never built (in the background since launch); false keeps it.
    var closeUnbuilt: (@MainActor (_ uri: String) async -> Bool)?
    /// Its items in the tab's context menu, added to `menu` above Close Tab: `workspace` is the editor area's, and
    /// `openBeside` opens a URI in a pane to the right.
    var menu: (@MainActor (_ menu: NSMenu, _ uri: String, _ workspace: String, _ openBeside: @escaping @MainActor (String) -> Void) -> Void)?
    /// `kelp browser`'s `action` on a page tab it made (`UIBrowser`).
    var browse: (@MainActor (_ tab: TabContent, _ action: String, _ args: JSONValue) async throws -> JSONValue)?
}

/// Everything one extension adds. Built-ins fill it in Swift; folders from extension.json.
/// A block of a built-in's own in the sidebar, under the projects (Machines): its view, made when the sidebar is.
package struct SidebarSection {
    package let id: String
    package let make: @MainActor () -> NSView
    package init(id: String, make: @escaping @MainActor () -> NSView) { self.id = id; self.make = make }
}

package struct Contributions {
    package init() {}
    package var panels: [PanelSpec] = []
    package var editors: [EditorSpec] = []
    package var commands: [CommandSpec] = []
    package var settings: [SettingsSection] = []
    var themes: [Theme] = []
    var iconThemes: [IconThemeSpec] = []
    var agents: [AgentManifest] = []
    package var tabs: [TabProvider] = []
    /// Blocks of its own in the sidebar, under the projects (Machines), made when the sidebar is and only while it's on.
    package var sidebarSections: [SidebarSection] = []
    /// In load order: `LanguageSpec.find` lets a later one replace an earlier one with the same id.
    package var languages: [LanguageSpec] = []
}

struct ExtensionInfo: Identifiable {
    let id: String, name: String, description: String, version: String, icon: String
    let builtin: Bool
    /// Can't be turned off (the IDE needs it).
    var essential = false
    var path: URL?
    /// The GitHub folder it was installed from (the library's, or another), for updates.
    var source: String?
    var error: String?
    /// A required tool is missing; shown, but contributes nothing.
    var unavailable: String?
    /// It runs commands and is new or changed since the user allowed it (`ExtensionTrust`); shown, but contributes nothing.
    var waitsToBeAllowed = false
    var enabled: Bool
    /// The tools it needs (its manifest's `requires`).
    var requires: [String] = []
}

/// The IDE is a shell around this: everything visible comes from an extension, built-in or a folder in ~/.kelp/extensions.
@MainActor
@Observable
package final class ExtensionRegistry {
    /// The app whose extensions these are: built-ins contribute with it.
    let app: AppModel
    package init(app: AppModel) { self.app = app }
    private(set) var extensions: [ExtensionInfo] = []
    private(set) package var all = Contributions()
    /// Bumped on every reload so views can refresh.
    private(set) package var revision = 0
    private(set) var disabledLoaded: Set<String> = []
    @ObservationIgnored private var watcher: FileWatcher?

    static var userDir: URL { Paths.root.appendingPathComponent("extensions") }
    /// Required tools (`requires`) the daemon found on its login-shell PATH, or didn't: command → found. One not asked yet
    /// counts as there (the daemon may still be reading that PATH, which takes seconds); each reload asks again, so a
    /// tool installed meanwhile counts, and an answer that changes anything reloads.
    static var tools: [String: Bool] = [:]
    @ObservationIgnored private var askingTools = false
    /// The versions asked about this run (`extensionDigest`), and the wait before asking.
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private let trustAsk = Debounce()

    /// Built-ins a clean install starts with switched off (`Builtin.offByDefault`); once settings.json has its own list,
    /// that list decides.
    func disabled(_ v: JSONValue?) -> Set<String> {
        v?.array.map { Set($0.compactMap(\.string)) } ?? Set(app.builtins.filter(\.offByDefault).map(\.info.id))
    }
    var disabled: Set<String> { disabled(app.settings.value("extensions.disabled")) }

    /// Loaded before the daemon's state was read: what was allowed wasn't known, so all that runs commands waited.
    private(set) var loadedWithoutState = false

    func reload() {
        loadedWithoutState = !app.uiState.loaded
        var infos: [ExtensionInfo] = []
        var merged = Contributions()
        let off = disabled
        disabledLoaded = off
        DeclarativeExtension.forget()
        func take(_ info: ExtensionInfo, _ c: Contributions) {
            var info = info; info.enabled = info.essential || !off.contains(info.id)
            infos.append(info)
            guard info.enabled else { DeclarativeExtension.forget(info.id); return }
            merged.panels += c.panels
            merged.editors += c.editors
            merged.commands += c.commands
            merged.settings += c.settings
            merged.themes += c.themes
            merged.iconThemes += c.iconThemes
            merged.agents += c.agents
            merged.tabs += c.tabs
            merged.languages += c.languages
            merged.sidebarSections += c.sidebarSections
        }
        for b in app.builtins { take(b.info, b.contribute(app)) }
        for folder in (try? FileManager.default.contentsOfDirectory(at: Self.userDir, includingPropertiesForKeys: nil)) ?? [] where Self.isFolder(folder) {
            let loaded = DeclarativeExtension.load(folder, tools: Self.tools, app: app)
            take(loaded.info, loaded.contributions)
        }
        merged.tabs.append(DeclarativeExtension.tabProvider(app))
        extensions = infos.sorted { ($0.builtin ? 0 : 1, $0.name) < ($1.builtin ? 0 : 1, $1.name) }
        all = merged
        revision += 1
        app.themes.apply()
        AgentSkills.write(app)
        app.publishUIState()
        askTools(Set(infos.flatMap(\.requires)))
        askTrust(infos)
    }

    /// Extensions that wait to be allowed are asked about once each version, after the folder has been still a moment (an
    /// agent writing one saves it many times). "Not Now" leaves it in Settings › Extensions, with Allow there.
    private func askTrust(_ infos: [ExtensionInfo]) {
        let users = infos.compactMap { $0.builtin ? nil : $0.path }
        Task { [weak self] in
            guard let self else { return }
            if await ExtensionTrust.adopt(users, app) { reload(); return }
            guard app.uiState.loaded else { return }   // nothing's asked before what was allowed is known
            let waiting = infos.filter(\.waitsToBeAllowed).compactMap(\.path).filter { asked.insert(IDE.extensionDigest($0)).inserted }
            guard !waiting.isEmpty else { return }
            trustAsk.after(3) { [weak self] in self?.ask(waiting) }
        }
    }

    private func ask(_ folders: [URL]) {
        Task {
            for f in folders where ExtensionTrust.waits(f, app) {
                if await ExtensionTrust.review(f, app) { reload() }
            }
        }
    }

    /// Allowed in Settings › Extensions, after the same look.
    func allow(_ e: ExtensionInfo) async {
        guard let f = e.path, await ExtensionTrust.review(f, app) else { return }
        reload()
    }

    /// Asks the daemon where `commands` are; reloads when that changes what's missing. Without a daemon, nothing: the
    /// reload after it connects asks.
    private func askTools(_ commands: Set<String>) {
        guard !commands.isEmpty, !askingTools else { return }
        askingTools = true
        Task {
            defer { askingTools = false }
            guard let found = await app.quiet(ProcessWhich(commands: commands.sorted())) else { return }
            let now = Dictionary(uniqueKeysWithValues: commands.map { ($0, found[$0] != nil) })
            guard now.contains(where: { Self.tools[$0.key] != $0.value }) else { return }
            Self.tools.merge(now) { _, new in new }
            reload()
        }
    }

    /// Live reload while someone (often an agent) edits an extension.
    func watch() {
        try? FileManager.default.createDirectory(at: Self.userDir, withIntermediateDirectories: true)
        let pending = Debounce()
        // delivered on main
        watcher = FileWatcher(root: Self.userDir.path) { [weak self] _ in MainActor.assumeIsolated { pending.after(0.3) { self?.reload() } } }
    }

    /// Follows symlinks: a VS Code extension can be linked in rather than copied.
    private static func isFolder(_ u: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) && dir.boolValue
    }

    /// Like VS Code's "Install from VSIX…": a .vsix (a zip with the extension in `extension/`) or an extension folder,
    /// copied into ~/.kelp/extensions. A version already there goes to the Trash. One with a Kelp manifest (it can run
    /// commands) is installed once the user has seen what it runs, as one from GitHub.
    func install(_ src: URL) async throws {
        let app = self.app, dir = Self.userDir, fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        let (folder, name) = try await Task.detached { @Sendable () async throws -> (URL, String) in
            let fm = FileManager.default
            guard src.pathExtension.lowercased() == "vsix" else { return (src, src.lastPathComponent) }
            let unzip = await Shell.exec(app, ["/usr/bin/ditto", "-x", "-k", src.path, tmp.path])
            let folder = tmp.appendingPathComponent("extension")
            guard unzip.code == 0, fm.fileExists(atPath: folder.appendingPathComponent("package.json").path) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: src.path])
            }
            let package = folder.appendingPathComponent("package.json")
            let name = (try? JSONDecoder().decode(VSCodePackage.self, from: Data(contentsOf: package)))?.manifest.id
            return (folder, name ?? src.deletingPathExtension().lastPathComponent)
        }.value
        if fm.fileExists(atPath: folder.appendingPathComponent("extension.json").path) {
            guard await ExtensionReview.approve(folder) else { return }
        }
        let installed = try await Task.detached { try IDE.installExtension(folder, as: name, in: dir) }.value
        _ = await ExtensionTrust.allow([installed], app)   // what the user just looked at
        reload()
    }

    /// From GitHub (the library's `source`, or any GitHub folder): downloaded, then installed once the user has seen what
    /// it runs. False when they said no or it failed (a banner says why).
    /// `files`: the library's SHA-256 of each, which the download must match.
    func install(source: String, files: [String: String]? = nil) async -> Bool {
        guard let fetched = await app.call(ExtensionFetch(source: source, files: files)) else { return false }
        let folder = URL(fileURLWithPath: fetched.folder), dir = Self.userDir
        guard await ExtensionReview.approve(folder) else { try? FileManager.default.removeItem(at: folder); return false }
        let installed: URL
        do { installed = try await Task.detached { try IDE.installExtension(folder, as: folder.lastPathComponent, in: dir, move: true) }.value }
        catch { Banner.show(String(localized: "Couldn't install \(folder.lastPathComponent): \(AppModel.message(error))"), style: .error); return false }
        _ = await ExtensionTrust.allow([installed], app)
        reload()
        return true
    }

    func setEnabled(_ id: String, _ on: Bool) {
        var off = disabled
        if on { off.remove(id) } else { off.insert(id) }
        app.settings.set("extensions.disabled", .array(off.sorted().map { .string($0) }))
    }

    func uninstall(_ id: String) {
        guard let e = extensions.first(where: { $0.id == id }), let path = e.path, !e.builtin else { return }
        try? FileManager.default.trashItem(at: path, resultingItemURL: nil)
        reload()
    }

    func tabProvider(for uri: String) -> TabProvider? {
        let scheme = TabURI.scheme(uri)
        if scheme == "ext", DeclarativeExtension.viewInfo(uri) == nil { return nil }   // its extension is off or gone
        return all.tabs.first { $0.schemes.contains(scheme) }
    }

    func command(_ id: String) -> CommandSpec? { all.commands.first { $0.id == id } }
    /// The key command `id` has: settings.json's `keys` over its own (`""`: none), `fallback` for one that isn't a
    /// registered command (the menus' own). What every menu and list that shows a key reads, so a rebound one reads the same.
    func key(_ id: String, fallback: String? = nil) -> KeySpec? {
        if let over = KeyBindings.overrides(app.settings)[id] { return over.isEmpty ? nil : KeySpec(over) }
        return (command(id)?.key ?? fallback).flatMap(KeySpec.init)
    }
    /// Runs the command (a menu item's, a key's); one whose extension is off does nothing.
    package func run(_ id: String, _ args: [String: JSONValue] = [:]) { command(id)?.run(args) }
}
