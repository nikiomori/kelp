import Agents
import AppKit
import Core
import DesignKit
import SwiftUI
import WorkbenchKit

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
    init(app: AppModel) { self.app = app }
    private(set) var extensions: [ExtensionInfo] = []
    private(set) package var all = Contributions()
    /// Bumped on every reload so views can refresh.
    private(set) var revision = 0
    private(set) var disabledLoaded: Set<String> = []
    @ObservationIgnored private var watcher: FileWatcher?

    static var userDir: URL { Paths.root.appendingPathComponent("extensions") }
    /// Required tools (`requires`) the daemon found on its login-shell PATH, or didn't: command → found. One not asked yet
    /// counts as there (the daemon may still be reading that PATH, which takes seconds); each reload asks again, so a
    /// tool installed meanwhile counts, and an answer that changes anything reloads.
    @ObservationIgnored private(set) var tools: [String: Bool] = [:]
    @ObservationIgnored private var askingTools = false
    /// The versions asked about this run (`extensionDigest`), and the wait before asking.
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private let trustAsk = Debounce()
    /// View definitions by "extension/view", for `ext:` tabs: only enabled extensions' (a reload starts over).
    @ObservationIgnored var views: [String: (ExtManifest, ExtManifest.ViewDef, URL)] = [:]
    /// The last manifest of each folder that loaded: a mistake while it's edited keeps this one working, the error beside it.
    @ObservationIgnored var lastGood: [String: ExtManifest] = [:]

    /// Built-ins a clean install starts with switched off (`Builtin.offByDefault`); once settings.json has its own list,
    /// that list decides.
    func disabled(_ list: [String]?) -> Set<String> {
        list.map(Set.init) ?? Set(app.builtins.filter(\.offByDefault).map(\.info.id))
    }
    var disabled: Set<String> { disabled(app.settings[SettingKeys.disabledExtensions]) }

    /// Loaded before the daemon's state was read: what was allowed wasn't known, so all that runs commands waited.
    private(set) var loadedWithoutState = false

    func reload() {
        loadedWithoutState = !app.uiState.loaded
        var infos: [ExtensionInfo] = []
        var merged = Contributions()
        let off = disabled
        disabledLoaded = off
        views = [:]   // uninstalled ones go
        func take(_ info: ExtensionInfo, _ c: Contributions) {
            var info = info
            info.enabled = info.essential || !off.contains(info.id)
            infos.append(info)
            guard info.enabled else {
                views = views.filter { $0.value.0.id != info.id }   // an extension turned off takes its views along
                return
            }
            merged.add(c)
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
            if await ExtensionTrust.adopt(users, app) {
                reload()
                return
            }
            guard app.uiState.loaded else { return }   // nothing's asked before what was allowed is known
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

    /// Allowed in Settings › Extensions, after the same look.
    func allow(_ e: ExtensionInfo) async {
        guard let folder = e.path, await ExtensionTrust.review(folder, app) else { return }
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
            guard now.contains(where: { tools[$0.key] != $0.value }) else { return }
            tools.merge(now) { _, new in new }
            reload()
        }
    }

    /// Live reload while someone (often an agent) edits an extension.
    func watch() {
        try? FileManager.default.createDirectory(at: Self.userDir, withIntermediateDirectories: true)
        let pending = Debounce()
        // delivered on main
        watcher = FileWatcher(root: Self.userDir.path) { [weak self] _ in
            MainActor.assumeIsolated { pending.after(0.3) { self?.reload() } }
        }
    }

    /// Follows symlinks: a VS Code extension can be linked in rather than copied.
    private static func isFolder(_ u: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) && dir.boolValue
    }

    func setEnabled(_ id: String, _ on: Bool) {
        var off = disabled
        if on { off.remove(id) } else { off.insert(id) }
        app.settings.set(SettingKeys.disabledExtensions, off.sorted())
    }

    func tabProvider(for uri: String) -> TabProvider? {
        let scheme = TabURI.scheme(uri)
        if scheme == "ext", viewInfo(uri) == nil { return nil }   // its extension is off or gone
        return all.tabs.first { $0.schemes.contains(scheme) }
    }

    /// Built-ins come first, so their ids win (`command`). An id agents may run (`UICommand.forAgents`) is never an
    /// extension's, even with the built-in that has it turned off: it would hand agents whatever that command runs.
    static func isAgentsOwn(_ command: CommandSpec) -> Bool { UICommand.forAgents.contains(command.id) }

    /// An `ext:` tab's view: its title and icon; nil when its extension is off or gone.
    func viewInfo(_ uri: String) -> (title: String, icon: String)? {
        views[ExtBridge.split(TabURI.body(uri)).view].map {
            ($0.1.title, $0.1.icon ?? $0.0.icon ?? "puzzlepiece.extension")
        }
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
