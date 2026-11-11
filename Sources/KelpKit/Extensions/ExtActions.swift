// What a declarative extension's actions do: templates expanded, URIs opened, commands run.
import Agents
import AppKit
import Core
import DesignKit
import SwiftUI
import WebKit
import WorkbenchKit

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
                if key.hasPrefix("setting:") {
                    return app.settings.value(String(key.dropFirst(8))).map(Self.text) ?? ""
                }
                return key.split(separator: ".").reduce(item) { $0?[String($1)] }.map(Self.text) ?? ""
            }
        }
        // A command gets the values as shell variables, never as text in it: $(…) or a newline in a title can't run.
        guard quote else { return ShellTemplate.substitute(template) { value($0) ?? "" } }
        // Each of them as KELP_<name> as well, for a command that reads them so: the item's fields and the workspace's.
        guard template.contains("KELP_") else { return ShellTemplate.fill(template, value) }
        var named = ["workspace.path", "workspace.branch", "workspace.name", "project.path", "file"].reduce(
            into: [String: String]()
        ) { $0[$1] = value($1) }
        if case .object(let fields)? = item { for (k, v) in fields { named[k] = Self.text(v) } }
        return ShellTemplate.fill(template, named: named, value)
    }

    /// An `open` action's URI: the extension's template with the item's values put in, for one that opens something. A
    /// URI that runs something (terminal:, agent:) never comes through a value (someone else's: an issue's link field set
    /// to terminal://…?cmd=…): nil then. The extension's own terminal: or agent: template is `runAction`'s.
    func openURI(_ template: String, item: JSONValue?) -> String? {
        Self.openableURI(
            TabURI.normalize(expand(template, item: item, quote: false), cwd: IDEContext.of(app).workspace?.path))
    }
    private static let runs = ["terminal", "agent"]

    /// What an `open` of the extension's own terminal: or agent: URI does, with the item's values put in the way the
    /// `terminal` and `agent` actions put them: a command's as shell variables (never text in it), a prompt typed for
    /// the user to send (never sent). A tmux session's name comes from the template alone. nil for another URI.
    enum RunAction: Equatable {
        case agent(String?, prompt: String?), terminal(command: String?, title: String?), tmux(String)
    }
    func runAction(_ template: String, item: JSONValue?) -> RunAction? {
        guard let colon = template.firstIndex(of: ":"), Self.runs.contains(String(template[..<colon])) else {
            return nil
        }
        var rest = template[template.index(after: colon)...]
        if rest.hasPrefix("//") { rest = rest.dropFirst(2) }
        let target = String(rest.prefix { $0 != "?" }).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var query: [String: String] = [:]
        if let questionMark = rest.firstIndex(of: "?") {
            for pair in rest[rest.index(after: questionMark)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map {
                    String($0).removingPercentEncoding ?? String($0)
                }
                if kv.count == 2 { query[kv[0]] = kv[1] }
            }
        }
        if template.hasPrefix("agent:") {
            return .agent(
                target.isEmpty ? nil : target, prompt: query["prompt"].map { expand($0, item: item, quote: false) })
        }
        if let name = query["tmux"] { return name.contains("${") ? nil : .tmux(name) }
        return .terminal(
            command: query["cmd"].map { expand($0, item: item, quote: true) },
            title: query["title"].map { expand($0, item: item, quote: false) })
    }

    /// A URI that opens something (a page, a file, a diff, a tab) rather than running a command or an agent; nil else.
    static func openableURI(_ uri: String) -> String? { runs.contains(TabURI.scheme(uri)) ? nil : uri }

    static func text(_ v: JSONValue) -> String {
        switch v {
        case .string(let text): text
        case .int(let number): String(number)
        case .double(let number): String(format: number == number.rounded() ? "%.0f" : "%g", number)
        case .bool(let flag): flag ? "true" : "false"
        case .null: ""
        default: (try? String(data: JSONEncoder().encode(v), encoding: .utf8)) ?? ""
        }
    }

    func perform(_ a: ExtManifest.ActionDef, item: JSONValue?, folder: URL, after: (() -> Void)? = nil) {
        guard let question = a.confirm else {
            act(a, item: item, folder: folder, after: after)
            return
        }
        let text = expand(question, item: item, quote: false)
        Task { if await confirm(text, action: a.title) { act(a, item: item, folder: folder, after: after) } }
    }

    private func act(_ a: ExtManifest.ActionDef, item: JSONValue?, folder: URL, after: (() -> Void)?) {
        if let command = a.terminal {
            app.workbench.starterForNewTab?.run(command: expand(command, item: item, quote: true), title: a.title)
        } else if let uri = a.open, let run = runAction(uri, item: item) {
            switch run {
            case .agent(let agent, let prompt):
                app.workbench.starterForNewTab?.newAgent(agent, prompt: prompt, draft: true)
            case .terminal(let command, let title):
                app.workbench.starterForNewTab?.run(command: command, title: title ?? a.title)
            case .tmux(let name):
                app.workbench.runURI(
                    "terminal:?tmux=" + (name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name))
            }
        } else if let uri = a.open {
            if let target = openURI(uri, item: item) {
                app.workbench.open(target)
            } else {
                Banner.show(
                    String(
                        localized:
                            "“\(a.title)” would run a command or an agent from its data; it opens links and files only."
                    ))
            }
        }
        // Typed, not sent: `item` is a command's output (an issue's title, a PR's body), someone else's words.
        else if let prompt = a.agent {
            app.workbench.starterForNewTab?.newAgent(nil, prompt: expand(prompt, item: item, quote: false), draft: true)
        } else if let script = a.run {
            let cmd = expand(script, item: item, quote: true)
            Task {
                let res = await Shell.run(
                    app, cmd, cwd: IDEContext.of(app).workspace?.path ?? folder.path,
                    extension: folder.lastPathComponent)
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
