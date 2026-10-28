import AppKit
import SwiftUI
import WebKit
import Core
import Agents
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
    struct BadgeDef: Decodable { var command: String; var refresh: Double? }
    struct ListDef: Decodable {
        struct StatusMap: Decodable { var field: String; var map: [String: String] }
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
        ExtManifest(id: publisher.map { "\($0).\(name)" } ?? name, name: displayName ?? name, version: version, description: description,
                    icon: "paintpalette", contributes: .init(iconThemes: contributes?.iconThemes))
    }
}

@MainActor
enum DeclarativeExtension {
    /// View definitions by "extension/view", for `ext:` tabs: only enabled extensions' (see `forget`).
    private static var views: [String: (ExtManifest, ExtManifest.ViewDef, URL)] = [:]

    /// A reload starts over (nil: every extension; uninstalled ones go); an extension turned off takes its views along.
    static func forget(_ id: String? = nil) { views = id.map { id in views.filter { $0.value.0.id != id } } ?? [:] }

    /// `tools`: required tools known to be there or not (`ExtensionRegistry.tools`); one not in it counts as there.
    static func load(_ folder: URL, tools: [String: Bool] = [:], app: AppModel) -> (info: ExtensionInfo, contributions: Contributions) {
        let fallbackId = folder.lastPathComponent
        do {
            let own = folder.appendingPathComponent("extension.json"), vscode = folder.appendingPathComponent("package.json")
            let m = !FileManager.default.fileExists(atPath: own.path) && FileManager.default.fileExists(atPath: vscode.path)
                ? try JSONDecoder().decode(VSCodePackage.self, from: Data(contentsOf: vscode)).manifest
                : try JSONDecoder().decode(ExtManifest.self, from: Data(contentsOf: own))
            var info = ExtensionInfo(id: m.id, name: m.name, description: m.description ?? "", version: m.version ?? "",
                                     icon: m.icon ?? "puzzlepiece.extension",
                                     builtin: false, path: folder, enabled: true)
            info.source = IDE.extensionSource(folder)
            info.requires = m.requires ?? []
            if let missing = info.requires.first(where: { tools[$0] == false }) {
                info.unavailable = String(localized: "Needs `\(missing)` — not found on this Mac.")
                return (info, Contributions())
            }
            return (info, contributions(m, folder, app))
        } catch {
            let msg = (error as? DecodingError).map(describe) ?? error.localizedDescription
            return (ExtensionInfo(id: fallbackId, name: fallbackId, description: "", version: "", icon: "exclamationmark.triangle", builtin: false,
                                  path: folder, error: msg, enabled: true), Contributions())
        }
    }

    private static func contributions(_ m: ExtManifest, _ folder: URL, _ app: AppModel) -> Contributions {
        var c = Contributions()
        let x = m.contributes
        for v in x?.panels ?? [] {
            views["\(m.id)/\(v.id)"] = (m, v, folder)
            let badge = ExtBadge()
            var poll: (@MainActor () async -> Void)?
            if let def = v.badge { poll = { await badge.poll(def, folder: folder, app: app) } }
            c.panels.append(PanelSpec(id: "\(m.id).\(v.id)", title: v.title, icon: v.icon ?? m.icon ?? "puzzlepiece.extension", extensionId: m.id,
                                      badge: { badge.value }, poll: poll) {
                viewController(m, v, folder, app, badge: badge)
            })
        }
        for v in x?.editors ?? [] {
            views["\(m.id)/\(v.id)"] = (m, v, folder)
            c.editors.append(EditorSpec(id: "\(m.id).\(v.id)", title: v.title, icon: v.icon ?? m.icon ?? "puzzlepiece.extension",
                                        uri: { _ in "ext:\(m.id)/\(v.id)" }))
        }
        for a in x?.commands ?? [] {
            c.commands.append(CommandSpec(id: a.id ?? "\(m.id).\(a.title)", title: a.title, key: a.key, menu: a.menu) { _ in
                ExtActions(app).perform(a, item: nil, folder: folder)
            })
        }
        if let s = x?.settings, !s.isEmpty {
            c.settings.append(SettingsSection(id: m.id, title: m.name, icon: m.icon ?? "puzzlepiece.extension", specs: s))
        }
        c.themes = x?.themes ?? []
        c.iconThemes = (x?.iconThemes ?? []).map {
            IconThemeSpec(id: $0.id, label: $0.label ?? $0.id, file: folder.appendingPathComponent($0.path).standardizedFileURL)
        }
        c.agents = x?.agents ?? []
        c.languages = x?.languages ?? []
        return c
    }

    static func viewInfo(_ uri: String) -> (title: String, icon: String)? {
        views[TabURI.body(uri)].map { ($0.1.title, $0.1.icon ?? $0.0.icon ?? "puzzlepiece.extension") }
    }

    /// Opens `ext:<extension>/<view>` tabs.
    static func tabProvider(_ app: AppModel) -> TabProvider {
        TabProvider(schemes: ["ext"]) { uri in
            guard let (m, v, folder) = views[TabURI.body(uri)] else { return nil }
            return ExtViewTab(uri: uri, title: v.title, icon: v.icon ?? m.icon ?? "puzzlepiece.extension", controller: viewController(m, v, folder, app))
        }
    }

    private static func viewController(_ m: ExtManifest, _ v: ExtManifest.ViewDef, _ folder: URL, _ app: AppModel, badge: ExtBadge? = nil) -> NSViewController {
        if let list = v.list { return hosting(ExtListView(def: list, folder: folder, app: app)) }
        if let web = v.web { return ExtWebController(page: folder.appendingPathComponent(web), folder: folder, app: app, badge: badge) }
        let vc = NSViewController(); vc.view = NSTextField(labelWithString: String(localized: "\(m.name): view “\(v.id)” has neither list nor web."))
        return vc
    }

    private static func describe(_ e: DecodingError) -> String {
        switch e {
        case .keyNotFound(let k, let c): "Missing “\(k.stringValue)” at \(path(c))"
        case .typeMismatch(_, let c), .valueNotFound(_, let c): "Wrong type at \(path(c)): \(c.debugDescription)"
        case .dataCorrupted(let c): "Invalid JSON: \(c.underlyingError?.localizedDescription ?? c.debugDescription)"
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

// MARK: running commands and actions

@MainActor
struct ExtActions {
    let app: AppModel
    init(_ app: AppModel) { self.app = app }

    /// `${Field}`, `${a.b}`, `${setting:key}`, `${workspace.path|branch|name}`, `${project.path}`, `${file}`. `quote` shell-quotes values.
    func expand(_ template: String, item: JSONValue?, quote: Bool) -> String {
        let ctx = IDEContext.of(app)
        let value: (String) -> String? = { key in
            switch key {
            case "workspace.path": return ctx.workspace?.path ?? ""
            case "workspace.branch": return ctx.workspace?.branch ?? ""
            case "workspace.name": return ctx.workspace?.displayName ?? ""
            case "project.path": return ctx.project?.path ?? ""
            case "file": return ctx.focusedFile ?? ""
            default:
                if key.hasPrefix("setting:") { return app.settings.value(String(key.dropFirst(8))).map(Self.text) ?? "" }
                return key.split(separator: ".").reduce(item) { $0?[String($1)] }.map(Self.text) ?? ""
            }
        }
        // A command gets the values as shell variables, never as text in it: $(…) or a newline in a title can't run.
        guard quote else { return ShellTemplate.substitute(template) { value($0) ?? "" } }
        // Each of them as KELP_<name> as well, for a command that reads them so: the item's fields and the workspace's.
        guard template.contains("KELP_") else { return ShellTemplate.fill(template, value) }
        var named = ["workspace.path", "workspace.branch", "workspace.name", "project.path", "file"].reduce(into: [String: String]()) { $0[$1] = value($1) }
        if case .object(let fields)? = item { for (k, v) in fields { named[k] = Self.text(v) } }
        return ShellTemplate.fill(template, named: named, value)
    }

    /// An `open` action's URI: the extension's template with the item's values put in, for one that opens something. A
    /// URI that runs something (terminal:, agent:) never comes through a value (someone else's: an issue's link field set
    /// to terminal://…?cmd=…): nil then. The extension's own terminal: or agent: template is `runAction`'s.
    func openURI(_ template: String, item: JSONValue?) -> String? {
        Self.openableURI(TabURI.normalize(expand(template, item: item, quote: false), cwd: IDEContext.of(app).workspace?.path))
    }
    private static let runs = ["terminal", "agent"]

    /// What an `open` of the extension's own terminal: or agent: URI does, with the item's values put in the way the
    /// `terminal` and `agent` actions put them: a command's as shell variables (never text in it), a prompt typed for
    /// the user to send (never sent). A tmux session's name comes from the template alone. nil for another URI.
    enum RunAction: Equatable { case agent(String?, prompt: String?), terminal(command: String?, title: String?), tmux(String) }
    func runAction(_ template: String, item: JSONValue?) -> RunAction? {
        guard let colon = template.firstIndex(of: ":"), Self.runs.contains(String(template[..<colon])) else { return nil }
        var rest = template[template.index(after: colon)...]
        if rest.hasPrefix("//") { rest = rest.dropFirst(2) }
        let target = String(rest.prefix { $0 != "?" }).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var query: [String: String] = [:]
        if let q = rest.firstIndex(of: "?") {
            for pair in rest[rest.index(after: q)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                if kv.count == 2 { query[kv[0]] = kv[1] }
            }
        }
        if template.hasPrefix("agent:") {
            return .agent(target.isEmpty ? nil : target, prompt: query["prompt"].map { expand($0, item: item, quote: false) })
        }
        if let name = query["tmux"] { return name.contains("${") ? nil : .tmux(name) }
        return .terminal(command: query["cmd"].map { expand($0, item: item, quote: true) }, title: query["title"].map { expand($0, item: item, quote: false) })
    }

    /// A URI that opens something (a page, a file, a diff, a tab) rather than running a command or an agent; nil else.
    static func openableURI(_ uri: String) -> String? { runs.contains(TabURI.scheme(uri)) ? nil : uri }

    static func text(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): s
        case .int(let i): String(i)
        case .double(let d): String(format: d == d.rounded() ? "%.0f" : "%g", d)
        case .bool(let b): b ? "true" : "false"
        case .null: ""
        default: (try? String(data: JSONEncoder().encode(v), encoding: .utf8)) ?? ""
        }
    }

    func perform(_ a: ExtManifest.ActionDef, item: JSONValue?, folder: URL, after: (() -> Void)? = nil) {
        guard let q = a.confirm else { act(a, item: item, folder: folder, after: after); return }
        let alert = NSAlert(); alert.messageText = expand(q, item: item, quote: false)
        alert.addButton(withTitle: a.title); alert.addButton(withTitle: String(localized: "Cancel"))
        Task { if await runSheet(alert) == .alertFirstButtonReturn { act(a, item: item, folder: folder, after: after) } }
    }

    private func act(_ a: ExtManifest.ActionDef, item: JSONValue?, folder: URL, after: (() -> Void)?) {
        if let t = a.terminal { app.workbench.editor?.run(command: expand(t, item: item, quote: true), title: a.title) }
        else if let o = a.open, let run = runAction(o, item: item) {
            switch run {
            case .agent(let agent, let prompt): app.workbench.editor?.newAgent(agent, prompt: prompt, draft: true)
            case .terminal(let command, let title): app.workbench.editor?.run(command: command, title: title ?? a.title)
            case .tmux(let name): app.workbench.open("terminal:?tmux=" + (name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name))
            }
        }
        else if let o = a.open {
            if let u = openURI(o, item: item) { app.workbench.open(u) }
            else { Banner.show(String(localized: "“\(a.title)” would run a command or an agent from its data; it opens links and files only.")) }
        }
        // Typed, not sent: `item` is a command's output (an issue's title, a PR's body), someone else's words.
        else if let p = a.agent { app.workbench.editor?.newAgent(nil, prompt: expand(p, item: item, quote: false), draft: true) }
        else if let r = a.run {
            let cmd = expand(r, item: item, quote: true)
            Task {
                let res = await Shell.run(app, cmd, cwd: IDEContext.of(app).workspace?.path ?? folder.path, extension: folder.lastPathComponent)
                if res.code != 0 {
                    let output = String((res.stderr.isEmpty ? res.stdout : res.stderr).suffix(400))
                    Banner.show(String(localized: "\(a.title) failed: \(output)"), style: .error)
                }
                after?()
            }
            return
        }
        after?()
    }
}

/// Runs a command the way the user's terminal would (login-shell PATH); `input` goes to its stdin. The daemon runs it
/// (`process.run`): the app starts no programs. `extension`: whose command it is (its folder's name) — refused once
/// that extension is off. A failure to reach the daemon or to start the program is code -1 with the reason as stderr.
package enum Shell {
    package struct Result: Sendable {
        package var code: Int32
        package var stdout: String
        package var stderr: String
    }
    package static func run(_ app: AppModel, _ command: String, cwd: String, input: String? = nil, timeout: TimeInterval = 60,
                            extension id: String? = nil) async -> Result {
        await exec(app, ["/bin/zsh", "-lc", command], cwd: cwd, input: input, timeout: timeout, extension: id)
    }

    /// A program by path (`argv[0]`), with the same PATH and a time limit (stopped then, with what it started).
    package static func exec(_ app: AppModel, _ argv: [String], cwd: String = NSHomeDirectory(), input: String? = nil, timeout: TimeInterval = 60,
                             extension id: String? = nil) async -> Result {
        do {
            let r = try await app.get(ProcessRun(argv: argv, cwd: cwd, stdin: input, timeLimit: timeout, extensionId: id))
            return Result(code: r.code, stdout: r.stdout, stderr: r.stderr)
        } catch {
            return Result(code: -1, stdout: "", stderr: (error as? RPCError)?.message ?? error.localizedDescription)
        }
    }
}

/// An extension panel's badge: its manifest's command, read while the inspector lists the panel, or `kelp.badge` from its page.
@MainActor @Observable
final class ExtBadge {
    var value: PanelBadge?

    func poll(_ def: ExtManifest.BadgeDef, folder: URL, app: AppModel) async {
        while !Task.isCancelled {
            let cmd = ExtActions(app).expand(def.command, item: nil, quote: true)
            let r = await Shell.run(app, cmd, cwd: IDEContext.of(app).workspace?.path ?? folder.path, extension: folder.lastPathComponent)
            // A command that fails is a red dot, its error the key: looked at once, it stays quiet until the error changes.
            let next = r.code == 0 ? PanelBadge(r.stdout) : PanelBadge(alert: true, key: String(r.stderr.prefix(200)))
            if next != value { value = next }
            try? await Task.sleep(for: .seconds(max(def.refresh ?? 60, 5)))
        }
    }
}
