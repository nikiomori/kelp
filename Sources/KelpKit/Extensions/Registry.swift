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
    static var tools: [String: Bool] = [:]
    @ObservationIgnored private var askingTools = false
    /// The versions asked about this run (`extensionDigest`), and the wait before asking.
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private let trustAsk = Debounce()

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
        DeclarativeExtension.forget()
        func take(_ info: ExtensionInfo, _ c: Contributions) {
            var info = info
            info.enabled = info.essential || !off.contains(info.id)
            infos.append(info)
            guard info.enabled else {
                DeclarativeExtension.forget(info.id)
                return
            }
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
            merged.sessionMarks += c.sessionMarks
            merged.branch = merged.branch ?? c.branch
            merged.ci = merged.ci ?? c.ci
            merged.pushed += c.pushed
            merged.plans = merged.plans ?? c.plans
            merged.servers = merged.servers ?? c.servers
            merged.launched += c.launched
            merged.dockMenu += c.dockMenu
            merged.dockUsage = merged.dockUsage ?? c.dockUsage
            merged.runs = merged.runs ?? c.runs
        }
        for b in app.builtins { take(b.info, b.contribute(app)) }
        for folder in (try? FileManager.default.contentsOfDirectory(at: Self.userDir, includingPropertiesForKeys: nil))
            ?? [] where Self.isFolder(folder)
        {
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
            if await ExtensionTrust.adopt(users, app) {
                reload()
                return
            }
            guard app.uiState.loaded else { return }   // nothing's asked before what was allowed is known
            let waiting = infos.filter(\.waitsToBeAllowed).compactMap(\.path).filter {
                asked.insert(IDE.extensionDigest($0)).inserted
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
        watcher = FileWatcher(root: Self.userDir.path) { [weak self] _ in
            MainActor.assumeIsolated { pending.after(0.3) { self?.reload() } }
        }
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
        guard await ExtensionReview.approve(folder) else {
            try? FileManager.default.removeItem(at: folder)
            return false
        }
        let installed: URL
        do {
            installed = try await Task.detached {
                try IDE.installExtension(folder, as: folder.lastPathComponent, in: dir, move: true)
            }.value
        } catch {
            Banner.show(
                String(localized: "Couldn't install \(folder.lastPathComponent): \(AppModel.message(error))"),
                style: .error)
            return false
        }
        _ = await ExtensionTrust.allow([installed], app)
        reload()
        return true
    }

    func setEnabled(_ id: String, _ on: Bool) {
        var off = disabled
        if on { off.remove(id) } else { off.insert(id) }
        app.settings.set(SettingKeys.disabledExtensions, off.sorted())
    }

    func uninstall(_ id: String) {
        guard let ext = extensions.first(where: { $0.id == id }), let path = ext.path, !ext.builtin else { return }
        do { try FileManager.default.trashItem(at: path, resultingItemURL: nil) } catch {
            let why = error.localizedDescription
            Banner.show(String(localized: "Couldn't move \(ext.name) to the Trash: \(why)"), style: .error)
        }
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
