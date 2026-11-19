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

    /// Fills in a template's `${Field}`, `${a.b}`, `${setting:key}`, `${workspace.path|branch|name}`, `${project.path}`
    /// and `${file}`. With `quote`, the values are shell-quoted.
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
        // A command gets the values as shell variables, never as text inside it, so $(…) or a newline in a title can't
        // run.
        guard quote else { return ShellTemplate.substitute(template) { value($0) ?? "" } }
        // Each value (the item's fields and the workspace's) is also given as KELP_<name>, for a command that reads
        // them that way.
        guard template.contains("KELP_") else { return ShellTemplate.fill(template, value) }
        var named = ["workspace.path", "workspace.branch", "workspace.name", "project.path", "file"].reduce(
            into: [String: String]()
        ) { $0[$1] = value($1) }
        if case .object(let fields)? = item { for (k, v) in fields { named[k] = Self.text(v) } }
        return ShellTemplate.fill(template, named: named, value)
    }

    /// Returns the URI an `open` action opens: the extension's template with the item's values filled in. A URI that
    /// runs something (terminal:, agent:) is never accepted when it comes from a value, because a value is someone
    /// else's text (an issue's link field set to terminal://…?cmd=…); then this returns nil. `runAction` handles the
    /// extension's own terminal: or agent: template.
    func openURI(_ template: String, item: JSONValue?) -> String? {
        Self.openableURI(
            TabURI.normalize(expand(template, item: item, quote: false), cwd: IDEContext.of(app).workspace?.path))
    }

    /// What an `open` of the extension's own terminal: or agent: URI does, with the item's values filled in the same
    /// way the `terminal` and `agent` actions fill them: a command gets them as shell variables (never as text inside
    /// it), and a prompt is typed for the user to send (never sent). A tmux session's name comes from the template
    /// alone. Returns nil for any other URI.
    enum RunAction: Equatable {
        case agent(String?, prompt: String?), terminal(command: String?, title: String?), tmux(String)
    }
    func runAction(_ template: String, item: JSONValue?) -> RunAction? {
        guard template.contains(":"), TabURI.runs(template) else { return nil }
        var rest = Substring(TabURI.body(template))
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
        if TabURI.scheme(template) == "agent" {
            return .agent(
                target.isEmpty ? nil : target, prompt: query["prompt"].map { expand($0, item: item, quote: false) })
        }
        if let name = query["tmux"] { return name.contains("${") ? nil : .tmux(name) }
        return .terminal(
            command: query["cmd"].map { expand($0, item: item, quote: true) },
            title: query["title"].map { expand($0, item: item, quote: false) })
    }

    /// Returns the URI if it opens something (a page, a file, a diff, a tab) rather than running a command or an agent,
    /// or nil otherwise.
    static func openableURI(_ uri: String) -> String? { TabURI.runs(uri) ? nil : uri }

    /// A value as text: a string as it is, a whole number without ".0", null as nothing, anything else as JSON.
    static func text(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): text
        case .int(let number): String(number)
        case .double(let number): String(format: number == number.rounded() ? "%.0f" : "%g", number)
        case .bool(let flag): flag ? "true" : "false"
        case .null: ""
        default: (try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? ""
        }
    }

    /// Does what the action says. `busy` hears when a `run` command has gone on for a second (true) and when it ends
    /// (false), for the button that ran it to show the wait.
    func perform(
        _ spec: ExtManifest.ActionDef, item: JSONValue?, folder: URL, busy: (@MainActor (Bool) -> Void)? = nil,
        after: (() -> Void)? = nil
    ) {
        guard let question = spec.confirm else {
            act(spec, item: item, folder: folder, busy: busy, after: after)
            return
        }
        let text = expand(question, item: item, quote: false)
        Task {
            guard await confirm(text, action: spec.title) else { return }
            act(spec, item: item, folder: folder, busy: busy, after: after)
        }
    }

    private func act(
        _ spec: ExtManifest.ActionDef, item: JSONValue?, folder: URL, busy: (@MainActor (Bool) -> Void)?,
        after: (() -> Void)?
    ) {
        if let command = spec.terminal {
            app.workbench.starterForNewTab?.run(
                command: expand(command, item: item, quote: true), title: spec.title)
        } else if let uri = spec.open, let run = runAction(uri, item: item) {
            switch run {
            case .agent(let agent, let prompt):
                app.workbench.starterForNewTab?.newAgent(agent, prompt: prompt, draft: true)
            case .terminal(let command, let title):
                app.workbench.starterForNewTab?.run(command: command, title: title ?? spec.title)
            case .tmux(let name):
                app.workbench.runURI(TabURI.terminal(["tmux": name]))
            }
        } else if let uri = spec.open {
            if let target = openURI(uri, item: item) {
                app.workbench.open(target)
            } else {
                Banner.show(
                    String(
                        localized:
                            "“\(spec.title)” would run a command or an agent from its data; it opens links and files only."
                    ))
            }
        }
        // The prompt is typed, not sent, because `item` is a command's output (an issue's title, a PR's body), which is
        // someone else's words.
        else if let prompt = spec.agent {
            app.workbench.starterForNewTab?.newAgent(nil, prompt: expand(prompt, item: item, quote: false), draft: true)
        } else if let script = spec.run {
            let cmd = expand(script, item: item, quote: true)
            let slow = whileSlow { busy?(true) }
            Task {
                let res = await Shell.run(
                    app, cmd, cwd: IDEContext.of(app).workspace?.path ?? folder.path,
                    extension: folder.lastPathComponent)
                slow.cancel()
                busy?(false)
                if res.code != 0 {
                    let output = String((res.stderr.isEmpty ? res.stdout : res.stderr).suffix(400))
                    Banner.show(String(localized: "\(spec.title) failed: \(output)"), style: .error)
                }
                after?()
            }
            return
        }
        after?()
    }
}
