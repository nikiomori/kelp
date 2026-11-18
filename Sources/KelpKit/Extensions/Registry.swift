import Agents
import AppKit
import Core
import DesignKit
import SwiftUI
import WorkbenchKit

struct ExtensionInfo: Identifiable {
    let id: String, name: String, description: String, version: String, icon: String
    let builtin: Bool
    /// Whether the extension can't be turned off (because the IDE needs it).
    var essential = false
    var path: URL?
    /// The GitHub folder the extension was installed from (the library's or another one), used for updates.
    var source: String?
    var error: String?
    /// Set when a required tool is missing. Such an extension is listed but contributes nothing.
    var unavailable: String?
    /// Whether the extension runs commands and is new or changed since the user allowed it (`ExtensionTrust`). Such an
    /// extension is listed but contributes nothing.
    var waitsToBeAllowed = false
    var enabled: Bool
    /// The tools it needs (its manifest's `requires`).
    var requires: [String] = []
}

/// The registry of extensions. The IDE is a shell around it: everything visible comes from an extension, either built
/// in or a folder in ~/.kelp/extensions.
@MainActor
@Observable
package final class ExtensionRegistry {
    /// The app these extensions belong to; built-ins use it to make their contributions.
    let app: AppModel
    init(app: AppModel) {
        self.app = app
        follow()
    }
    private(set) var extensions: [ExtensionInfo] = []
    private(set) package var all = Contributions()
    /// Every setting's row, by its key (when two sections declare a setting, the first section's row). Anything that
    /// needs a setting's default, range, names or choices reads it here.
    private(set) var specs: [String: SettingSpec] = [:]
    /// Bumped on every reload so views can refresh.
    private(set) var revision = 0
    private(set) var disabledLoaded: Set<String> = []
    @ObservationIgnored private var watcher: FileWatcher?

    static var userDir: URL { Paths.extensions }
    /// Whether the daemon found each required tool (`requires`) on its login-shell PATH, as command → found. A tool not
    /// asked about yet counts as there, because the daemon may still be reading that PATH, which takes seconds. Each
    /// reload asks again, so a tool installed meanwhile counts, and an answer that changes anything reloads.
    @ObservationIgnored private(set) var tools: [String: Bool] = [:]
    @ObservationIgnored private var askingTools = false
    /// The extension versions (`extensionDigest`) already asked about since Kelp started, and the wait before asking.
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private let trustAsk = Debounce()
    /// View definitions keyed by "extension/view", for `ext:` tabs. Only enabled extensions have entries, and a reload
    /// starts the map over.
    @ObservationIgnored var views: [String: (ExtManifest, ExtManifest.ViewDef, URL)] = [:]
    /// The last manifest of each folder that loaded. While a manifest is being edited, a mistake keeps this one
    /// working, with the error shown beside it.
    @ObservationIgnored var lastGood: [String: ExtManifest] = [:]

    /// Returns the switched-off extensions. A clean install starts with the `Builtin.offByDefault` built-ins off; once
    /// settings.json has its own list, that list decides.
    func disabled(_ list: [String]?) -> Set<String> {
        list.map(Set.init) ?? Set(app.builtins.filter(\.offByDefault).map(\.info.id))
    }
    var disabled: Set<String> { disabled(app.settings[SettingKeys.disabledExtensions]) }

    /// Whether the extensions loaded before the daemon's state was read. Then what was allowed wasn't known, so every
    /// extension that runs commands waited.
    private(set) var loadedWithoutState = false

    func reload() {
        loadedWithoutState = !app.uiState.loaded
        var infos: [ExtensionInfo] = []
        var merged = Contributions()
        let off = disabled
        disabledLoaded = off
        views = [:]   // this drops the views of uninstalled extensions
        func take(_ info: ExtensionInfo, _ contributions: Contributions) {
            var info = info
            info.enabled = info.essential || !off.contains(info.id)
            infos.append(info)
            guard info.enabled else {
                views = views.filter { $0.value.0.id != info.id }   // an extension turned off takes its views along
                return
            }
            merged.add(contributions)
        }
        for b in app.builtins { take(b.info, b.contribute(app)) }
        for folder in (try? FileManager.default.contentsOfDirectory(at: Self.userDir, includingPropertiesForKeys: nil))
            ?? [] where Self.isFolder(folder)
        {
            var loaded = DeclarativeExtension.load(folder, tools: tools, app: app)
            loaded.contributions.commands.removeAll(where: Self.isAgentsOwn)
            take(loaded.info, loaded.contributions)
        }
        merged.tabs.append(DeclarativeExtension.tabProvider(app))
        extensions = infos.sorted { ($0.builtin ? 0 : 1, $0.name) < ($1.builtin ? 0 : 1, $1.name) }
        all = merged
        specs = Dictionary(merged.settings.flatMap(\.specs).map { ($0.key, $0) }) { first, _ in first }
        revision += 1
        app.publishUIState()
        askTools(Set(infos.flatMap(\.requires)))
        askTrust(infos)
    }

    /// Follows settings.json. Switching a built-in or an extension on or off loads the extensions again, and the skills
    /// are written again when one of their switches or the extensions change.
    private func follow() {
        track(owner: self, now: false) { [weak self] in
            self?.disabled ?? []
        } changed: { [weak self] off in
            // While a connection is being read, `AppModel.opened` loads the extensions once when it ends.
            guard let self, !extensions.isEmpty, off != disabledLoaded, !app.opening else { return }
            reload()
        }
        track(owner: self, now: false) { [weak self] in
            self?.skillsRead
        } changed: { [weak self] _ in
            guard let self else { return }
            AgentSkills.write(app)
        }
    }

    /// What the written skills depend on: the loaded extensions (their skills, settings and themes) and each skill
    /// switch.
    private var skillsRead: SkillsRead {
        let settings = app.settings
        let switches = [SettingKeys.skillExtensions, SettingKeys.skillSettings] + all.skills.compactMap(\.setting)
        return SkillsRead(revision: revision, on: switches.map { settings[$0] })
    }
    private struct SkillsRead: Equatable {
        let revision: Int
        let on: [Bool]
    }

    /// Asks the user about each extension that waits to be allowed, once per version, after its folder has been still
    /// for a moment (an agent writing an extension saves it many times). "Not Now" leaves the extension in Settings ›
    /// Extensions, with Allow there.
    private func askTrust(_ infos: [ExtensionInfo]) {
        let users = infos.compactMap { $0.builtin ? nil : $0.path }
        Task { [weak self] in
            guard let self else { return }
            if await ExtensionTrust.adopt(users, app) {
                reload()
                return
            }
            guard app.uiState.loaded else { return }   // nothing is asked until Kelp knows what was allowed
            let waiting = infos.filter(\.waitsToBeAllowed).compactMap(\.path).filter {
                asked.insert(ExtensionFiles.extensionDigest($0)).inserted
            }
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

    /// Allows an extension from Settings › Extensions, after the same review the prompt shows.
    func allow(_ extensionInfo: ExtensionInfo) async {
        guard let folder = extensionInfo.path, await ExtensionTrust.review(folder, app) else { return }
        reload()
    }

    /// Asks the daemon where `commands` are, and reloads when the answer changes what's missing. Without a daemon it
    /// does nothing, because the reload after the daemon connects asks.
    private func askTools(_ commands: Set<String>) {
        guard !commands.isEmpty, !askingTools else { return }
        askingTools = true
        Task {
            defer { askingTools = false }
            guard let found = await app.quiet(ProcessWhich(commands: commands.sorted())) else { return }
            let now = Dictionary(uniqueKeysWithValues: commands.map { ($0, found[$0] != nil) })
            let changed = now.contains { (tools[$0.key] ?? true) != $0.value }   // one not asked yet counted as there
            tools.merge(now) { _, new in new }
            if changed { reload() }
        }
    }

    /// Live reload while someone (often an agent) edits an extension.
    func watch() {
        try? FileManager.default.createDirectory(at: Self.userDir, withIntermediateDirectories: true)
        let pending = Debounce()
        // FileWatcher delivers on the main thread
        watcher = FileWatcher(root: Self.userDir.path) { [weak self] _ in
            MainActor.assumeIsolated { pending.after(0.3) { self?.reload() } }
        }
    }

    /// Whether the URL is a folder, following symlinks, because a VS Code extension can be linked in rather than
    /// copied.
    private static func isFolder(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    func setEnabled(_ id: String, _ on: Bool) {
        var off = disabled
        if on { off.remove(id) } else { off.insert(id) }
        app.settings.set(SettingKeys.disabledExtensions, off.sorted())
    }

    /// Every built-in's marks on a row (`RowMark`), in load order.
    package func rowMarks(_ row: SidebarItem.Kind) -> [RowMark] { all.rowMarks.flatMap { $0(row) } }

    func tabProvider(for uri: String) -> TabProvider? {
        let scheme = TabURI.scheme(uri)
        if scheme == "ext", viewInfo(uri) == nil { return nil }   // its extension is off or gone
        return all.tabs.first { $0.schemes.contains(scheme) }
    }

    /// Whether a command's id is one agents may run (`UICommand.forAgents`). Built-ins come first, so their ids win
    /// (`command`). Such an id never goes to a folder extension, even when the built-in that has it is turned off,
    /// because that would hand agents whatever the extension's command runs.
    static func isAgentsOwn(_ command: CommandSpec) -> Bool { UICommand.forAgents.contains(command.id) }

    /// An `ext:` tab's view: its title and icon; nil when its extension is off or gone.
    func viewInfo(_ uri: String) -> (title: String, icon: String)? {
        views[ExtBridge.split(TabURI.body(uri)).view].map {
            ($0.1.title, $0.1.icon ?? $0.0.icon ?? "puzzlepiece.extension")
        }
    }

    func command(_ id: String) -> CommandSpec? { all.commands.first { $0.id == id } }
    /// Returns the key for command `id`. settings.json's `keys` override the command's own (`""` means no key), and
    /// `fallback` serves an id that isn't a registered command (the menus' own items). Every menu and list that shows a
    /// key reads it here, so a rebound key shows the same everywhere.
    func key(_ id: String, fallback: String? = nil) -> KeySpec? {
        if let over = KeyBindings.overrides(app.settings)[id] { return over.isEmpty ? nil : KeySpec(over) }
        return (command(id)?.key ?? fallback).flatMap(KeySpec.init)
    }
    /// Returns command `id`'s key as the menus show it ("⌘W"), or nil when it has none: what a sentence that names the
    /// key puts in it.
    package func keyText(_ id: String) -> String? { key(id).map(KeyBindings.display) }
    /// Returns `title` with command `id`'s key after it, as a tooltip says it ("Close Tab (⌘W)"), and `title` alone
    /// when the command has no key. A key typed into the tooltip's own text stayed the old one after a rebinding.
    package func hint(_ title: String, _ id: String) -> String { keyText(id).map { "\(title) (\($0))" } ?? title }
    /// Runs the command (from a menu item or a key). A command whose extension is off does nothing.
    package func run(_ id: String, _ args: [String: JSONValue] = [:]) { command(id)?.run(args) }
}
