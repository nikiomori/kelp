import Agents
import AppKit
import Core
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
    /// VS Code's own shape: the theme file is in VS Code's file icon theme format.
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
    /// A panel's icon badge: what `command` prints (`PanelBadge(_:)`), read every `refresh` seconds (60 by default).
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
        var status: StatusMap?
        var empty: String?
        var actions: [ActionDef]?, toolbar: [ActionDef]?
    }
    /// A list action, toolbar button or command: exactly one of terminal / run / open / agent.
    struct ActionDef: Decodable {
        var id: String?
        var title: String
        var icon: String?, key: String?, confirm: String?
        /// Commands only: the menu bar menu it's listed in (Tools when left out).
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

/// A folder's extension.json (or a VS Code package.json) made into contributions. What it keeps between reloads, the
/// views `ext:` tabs open and each folder's last manifest that worked, is `app`'s registry's.
@MainActor
enum DeclarativeExtension {
    /// `tools`: required tools known to be there or not (`ExtensionRegistry.tools`); one not in it counts as there.
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
                // nothing worked before: the error alone
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

    private static func contributions(_ m: ExtManifest, _ folder: URL, _ app: AppModel) -> Contributions {
        var result = Contributions()
        let contributes = m.contributes
        for v in contributes?.panels ?? [] {
            app.extensions.views["\(m.id)/\(v.id)"] = (m, v, folder)
            let badge = ExtBadge()
            var poll: (@MainActor () async -> Void)?
            if let def = v.badge { poll = { await badge.poll(def, folder: folder, app: app) } }
            result.panels.append(
                PanelSpec(
                    id: "\(m.id).\(v.id)", title: v.title, icon: v.icon ?? m.icon ?? "puzzlepiece.extension",
                    extensionId: m.id,
                    badge: { badge.value }, poll: poll
                ) {
                    viewController(m, v, folder, app, badge: badge)
                })
        }
        for v in contributes?.editors ?? [] {
            app.extensions.views["\(m.id)/\(v.id)"] = (m, v, folder)
            result.editors.append(
                EditorSpec(
                    id: "\(m.id).\(v.id)", title: v.title, icon: v.icon ?? m.icon ?? "puzzlepiece.extension",
                    uri: { _ in "ext:\(m.id)/\(v.id)" }))
        }
        for a in contributes?.commands ?? [] {
            result.commands.append(
                CommandSpec(id: a.id ?? "\(m.id).\(a.title)", title: a.title, key: a.key, menu: a.menu) { _ in
                    ExtActions(app).perform(a, item: nil, folder: folder)
                })
        }
        if let specs = contributes?.settings, !specs.isEmpty {
            result.settings.append(
                SettingsSection(id: m.id, title: m.name, icon: m.icon ?? "puzzlepiece.extension", specs: specs))
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
        _ m: ExtManifest, _ v: ExtManifest.ViewDef, _ folder: URL, _ app: AppModel, badge: ExtBadge? = nil,
        props: [String: String] = [:]
    ) -> NSViewController {
        if let list = v.list { return hosting(ExtListView(def: list, folder: folder, app: app)) }
        if let web = v.web {
            return ExtWebController(
                page: folder.appendingPathComponent(web), folder: folder, app: app, badge: badge, props: props)
        }
        let vc = NSViewController()
        vc.view = NSTextField(labelWithString: String(localized: "\(m.name): view “\(v.id)” has neither list nor web."))
        return vc
    }

    private static func describe(_ e: DecodingError) -> String {
        switch e {
        case .keyNotFound(let key, let context): "Missing “\(key.stringValue)” at \(path(context))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            "Wrong type at \(path(context)): \(context.debugDescription)"
        case .dataCorrupted(let context):
            "Invalid JSON: \(context.underlyingError?.localizedDescription ?? context.debugDescription)"
        @unknown default: "\(e)"
        }
    }
    private static func path(_ c: DecodingError.Context) -> String {
        c.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
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

/// An extension panel's badge: its manifest's command, read while the inspector lists the panel, or `kelp.badge` from its page.
@MainActor @Observable
final class ExtBadge {
    var value: PanelBadge?

    func poll(_ def: ExtManifest.BadgeDef, folder: URL, app: AppModel) async {
        while !Task.isCancelled {
            let cmd = ExtActions(app).expand(def.command, item: nil, quote: true)
            let result = await Shell.run(
                app, cmd, cwd: IDEContext.of(app).workspace?.path ?? folder.path, extension: folder.lastPathComponent)
            // A command that fails is a red dot, its error the key: looked at once, it stays quiet until the error changes.
            let next =
                result.code == 0
                ? PanelBadge(result.stdout) : PanelBadge(alert: true, key: String(result.stderr.prefix(200)))
            if next != value { value = next }
            try? await Task.sleep(for: .seconds(max(def.refresh ?? 60, 5)))
        }
    }
}
