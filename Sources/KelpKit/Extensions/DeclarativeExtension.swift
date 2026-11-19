import Agents
import AppKit
import Core
import DesignKit
import SwiftUI
import WebKit
import WorkbenchKit

/// extension.json, as described in docs/extensions.md.
struct ExtManifest: Decodable {
    struct Contrib: Decodable {
        var panels: [ViewDef]?, editors: [ViewDef]?, commands: [ActionDef]?
        var settings: [SettingSpec]?, themes: [Theme]?, iconThemes: [IconThemeRef]?, agents: [AgentManifest]?
        var languages: [LanguageSpec]?
    }
    /// An icon theme entry in VS Code's own shape; the theme file uses VS Code's file icon theme format.
    struct IconThemeRef: Decodable {
        var id: String
        var label: String?
        var path: String
    }
    struct ViewDef: Decodable {
        var id: String
        var title: String
        var icon: String?
        var list: ListDef?
        var web: String?
        var badge: BadgeDef?
    }
    /// The badge on a panel's icon: what `command` prints (`PanelBadge(_:)`), run again every `refresh` seconds (60 by
    /// default).
    struct BadgeDef: Decodable {
        var command: String
        var refresh: Double?
    }
    struct ListDef: Decodable {
        struct StatusMap: Decodable {
            var field: String
            var map: [String: String]
        }
        var command: String
        var refresh: Double?
        var title: String?, subtitle: String?, icon: String?
        /// A file path: dragging the row drags that file.
        var drag: String?
        var status: StatusMap?
        var empty: String?
        var actions: [ActionDef]?, toolbar: [ActionDef]?
    }
    /// A list action, toolbar button or command: exactly one of terminal / run / open / agent.
    struct ActionDef: Decodable {
        var id: String?
        var title: String
        var icon: String?, key: String?, confirm: String?
        /// For commands only: the menu bar menu the command is listed in (Tools when left out).
        var menu: String?
        var terminal: String?, run: String?, open: String?, agent: String?
    }
    var id: String
    var name: String
    var version: String?
    var description: String?
    var icon: String?
    /// Commands that must be on PATH (e.g. "docker"); without them the extension stays inactive.
    var requires: [String]?
    var contributes: Contrib?
}

/// A VS Code extension's package.json. Kelp uses what it understands of it: file icon themes.
struct VSCodePackage: Decodable {
    struct Contrib: Decodable { var iconThemes: [ExtManifest.IconThemeRef]? }
    var name: String, publisher: String?, displayName: String?, version: String?, description: String?
    var contributes: Contrib?

    var manifest: ExtManifest {
        ExtManifest(
            id: publisher.map { "\($0).\(name)" } ?? name, name: displayName ?? name, version: version,
            description: description,
            icon: "paintpalette", contributes: .init(iconThemes: contributes?.iconThemes))
    }
}

/// Turns a folder's extension.json (or a VS Code package.json) into contributions. What it keeps between reloads (the
/// views that `ext:` tabs open, and each folder's last manifest that worked) is stored in the registry of `app`.
@MainActor
enum DeclarativeExtension {
    /// Loads one folder. `tools` says which required tools are known to be there or not (`ExtensionRegistry.tools`); a
    /// tool not in it counts as there.
    static func load(_ folder: URL, tools: [String: Bool] = [:], app: AppModel) -> (
        info: ExtensionInfo, contributions: Contributions
    ) {
        let fallbackId = folder.lastPathComponent
        do {
            let own = folder.appendingPathComponent("extension.json"),
                vscode = folder.appendingPathComponent("package.json")
            let manifest: ExtManifest, problem: String?
            do {
                manifest =
                    !FileManager.default.fileExists(atPath: own.path)
                        && FileManager.default.fileExists(atPath: vscode.path)
                    ? try JSONDecoder().decode(VSCodePackage.self, from: Data(contentsOf: vscode)).manifest
                    : try JSONDecoder().decode(ExtManifest.self, from: Data(contentsOf: own))
                app.extensions.lastGood[folder.path] = manifest
                problem = nil
            } catch {
                // when no manifest of this folder worked before, only the error is shown
                guard let kept = app.extensions.lastGood[folder.path] else { throw error }
                manifest = kept
                problem = (error as? DecodingError).map(describe) ?? error.localizedDescription
            }
            var info = ExtensionInfo(
                id: manifest.id, name: manifest.name, description: manifest.description ?? "",
                version: manifest.version ?? "",
                icon: manifest.icon ?? "puzzlepiece.extension",
                builtin: false, path: folder, enabled: true)
            info.source = ExtensionFiles.extensionSource(folder)
            info.error =
                problem.map { String(localized: "\($0) Still running the version from before the change.") }
                ?? manifest.contributes?.settings?.lazy.compactMap(\.problem).first
            info.requires = manifest.requires ?? []
            if let missing = info.requires.first(where: { tools[$0] == false }) {
                info.unavailable = String(localized: "Needs `\(missing)` — not found on this Mac.")
                return (info, Contributions())
            }
            if ExtensionTrust.waits(folder, app) {
                info.waitsToBeAllowed = true
                return (info, Contributions())
            }
            return (info, contributions(manifest, folder, app))
        } catch {
            let msg = (error as? DecodingError).map(describe) ?? error.localizedDescription
            return (
                ExtensionInfo(
                    id: fallbackId, name: fallbackId, description: "", version: "", icon: "exclamationmark.triangle",
                    builtin: false,
                    path: folder, error: msg, enabled: true), Contributions()
            )
        }
    }

    private static func contributions(_ extManifest: ExtManifest, _ folder: URL, _ app: AppModel) -> Contributions {
        var result = Contributions()
        let contributes = extManifest.contributes
        for v in contributes?.panels ?? [] {
            app.extensions.views["\(extManifest.id)/\(v.id)"] = (extManifest, v, folder)
            let badge = ExtBadge()
            var poll: (@MainActor () async -> Void)?
            if let def = v.badge { poll = { await badge.poll(def, folder: folder, app: app) } }
            result.panels.append(
                PanelSpec(
                    id: "\(extManifest.id).\(v.id)", title: v.title,
                    icon: v.icon ?? extManifest.icon ?? "puzzlepiece.extension",
                    extensionId: extManifest.id,
                    badge: { badge.value }, poll: poll
                ) {
                    viewController(extManifest, v, folder, app, badge: badge)
                })
        }
        for v in contributes?.editors ?? [] {
            app.extensions.views["\(extManifest.id)/\(v.id)"] = (extManifest, v, folder)
            result.editors.append(
                EditorSpec(
                    id: "\(extManifest.id).\(v.id)", title: v.title,
                    icon: v.icon ?? extManifest.icon ?? "puzzlepiece.extension",
                    uri: { _ in "ext:\(extManifest.id)/\(v.id)" }))
        }
        for a in contributes?.commands ?? [] {
            result.commands.append(
                CommandSpec(id: a.id ?? "\(extManifest.id).\(a.title)", title: a.title, key: a.key, menu: a.menu) { _ in
                    ExtActions(app).perform(a, item: nil, folder: folder)
                })
        }
        if let specs = contributes?.settings, !specs.isEmpty {
            result.settings.append(
                SettingsSection(
                    id: extManifest.id, title: extManifest.name, icon: extManifest.icon ?? "puzzlepiece.extension",
                    specs: specs))
        }
        result.themes = contributes?.themes ?? []
        result.iconThemes = (contributes?.iconThemes ?? []).map {
            IconThemeSpec(
                id: $0.id, label: $0.label ?? $0.id, file: folder.appendingPathComponent($0.path).standardizedFileURL)
        }
        result.agents = contributes?.agents ?? []
        result.languages = contributes?.languages ?? []
        return result
    }

    /// Opens `ext:<extension>/<view>` tabs.
    static func tabProvider(_ app: AppModel) -> TabProvider {
        TabProvider(schemes: ["ext"]) { uri in
            let (view, props) = ExtBridge.split(TabURI.body(uri))   // ext:my.ext/view?file=a.txt: kelp.props
            guard let (m, v, folder) = app.extensions.views[view] else { return nil }
            return ExtViewTab(
                uri: uri, title: v.title, icon: v.icon ?? m.icon ?? "puzzlepiece.extension",
                controller: viewController(m, v, folder, app, props: props))
        }
    }

    private static func viewController(
        _ extManifest: ExtManifest, _ viewDef: ExtManifest.ViewDef, _ folder: URL, _ app: AppModel,
        badge: ExtBadge? = nil,
        props: [String: String] = [:]
    ) -> NSViewController {
        if let list = viewDef.list { return hosting(ExtListView(def: list, folder: folder, app: app)) }
        if let web = viewDef.web {
            // A missing page would load nothing and leave the panel blank, with no word of why.
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(web).path) else {
                let empty = EmptyStateView(), vc = NSViewController()
                empty.show(
                    String(localized: "No Page to Show"), symbol: "exclamationmark.triangle",
                    text: String(localized: "\(extManifest.name) has no file “\(web)” in its folder."),
                    fix: "kelp ext check \(ShellQuote.word(folder.path))")
                vc.view = empty
                return vc
            }
            return ExtWebController(
                page: folder.appendingPathComponent(web), folder: folder, app: app, badge: badge, props: props)
        }
        // A view that names neither gets the panel's error block, as a missing page does, not a bare line in a corner.
        let empty = EmptyStateView(), vc = NSViewController()
        empty.showError(
            String(localized: "Nothing to Show"),
            text: String(localized: "\(extManifest.name): view “\(viewDef.id)” has neither list nor web."),
            fix: "kelp ext check \(ShellQuote.word(folder.path))")
        vc.view = empty
        return vc
    }

    private static func describe(_ decodingError: DecodingError) -> String {
        switch decodingError {
        case .keyNotFound(let key, let context): "Missing “\(key.stringValue)” at \(path(context))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            "Wrong type at \(path(context)): \(context.debugDescription)"
        case .dataCorrupted(let context):
            "Invalid JSON: \(context.underlyingError?.localizedDescription ?? context.debugDescription)"
        @unknown default: "\(decodingError)"
        }
    }
    private static func path(_ context: DecodingError.Context) -> String {
        context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
    }
}

/// An extension view in the editor area.
@MainActor
final class ExtViewTab: TabContent {
    let uri: String, title: String
    let icon: NSImage?
    private let controller: NSViewController
    var view: NSView { controller.view }
    init(uri: String, title: String, icon: String, controller: NSViewController) {
        self.uri = uri
        self.title = title
        self.icon = .symbol(icon)
        self.controller = controller
    }
    func focus() {}
}

/// The badge of an extension's panel. It comes from the manifest's command, run while the inspector lists the panel, or
/// from `kelp.badge` on the panel's page.
@MainActor @Observable
final class ExtBadge {
    var value: PanelBadge?

    func poll(_ def: ExtManifest.BadgeDef, folder: URL, app: AppModel) async {
        while !Task.isCancelled {
            if !app.away {   // nobody sees the badge while the window is away, so the command waits
                let cmd = ExtActions(app).expand(def.command, item: nil, quote: true)
                let cwd = IDEContext.of(app).workspace?.path ?? folder.path
                let result = await Shell.run(app, cmd, cwd: cwd, extension: folder.lastPathComponent)
                // A command that fails gives a red dot keyed by its error. Once the user has looked at it, the dot
                // stays off until the error changes.
                let next =
                    result.code == 0
                    ? PanelBadge(result.stdout) : PanelBadge(alert: true, key: String(result.stderr.prefix(200)))
                if next != value { value = next }
            }
            try? await Task.sleep(for: .seconds(app.away ? 5 : max(def.refresh ?? 60, 5)))
        }
    }
}
