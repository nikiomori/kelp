import Foundation
import Core

/// Kelp's skills for agents: how to write and connect an extension, how to change settings. Each is a Claude Code
/// plugin in ~/.kelp/agent-skills that the daemon loads per session (--plugin-dir); turning one off in
/// Settings › Agents removes it. Nothing is written to the agent's own config.
@MainActor
enum AgentSkills {
    static func write(_ app: AppModel) {
        let s = app.settings
        put("kelp-extensions", on: s.bool("agents.skills.extensions") != false,
            description: "Use when the user wants something added to or changed in Kelp, the IDE this session runs in: a panel, list, tab, command, "
                + "setting, theme or language server — e.g. “add a Kelp panel with my Docker containers”, “show Android emulators in Kelp”. Kelp extensions are "
                + "extension.json folders in $KELP_HOME/extensions; they are not Claude Code plugins, mods, hooks or MCP servers.",
            body: extensionsSteps(ExtensionRegistry.userDir.path) + IDE.extensionGuide)
        put("kelp-settings", on: s.bool("agents.skills.settings") != false,
            description: "Use when the user wants to see or change how Kelp, the IDE this session runs in, is set up: theme, fonts, editor, "
                + "terminal, agents, turning extensions on or off. Done with the kelp CLI (kelp settings set …), not Claude Code's own settings.",
            body: settingsGuide(app))
        put("kelp-terminals", on: s.bool("agents.skills.terminals") != false,
            description: "Use when you run tests, a build or a dev server, or work through a long multi-step task, in Kelp, the IDE this session runs "
                + "in: run the command in a Kelp tab the user can watch, wait for it, read what it printed, and show your progress on your row.",
            body: terminalsGuide)
        try? IDE.writeGuide(in: ExtensionRegistry.userDir)   // the guide also sits next to the user's extensions, for people
    }

    /// The exact folder this Kelp loads extensions from (the guide below says ~/.kelp, which a custom KELP_HOME changes).
    private static func extensionsSteps(_ folder: String) -> String { """
        # Adding something to Kelp

        This session runs inside Kelp and the `kelp` CLI is on PATH. Kelp loads extensions from `\(folder)`.

        0. Look in the library first: `kelp ext search <word>`. When one fits, `kelp ext install <id>` and you're done.
        1. Write `\(folder)/<id>/extension.json` (and any script or HTML it uses next to it) following the guide below.
           Prefer a `list` view fed by a shell command that prints one JSON object per line.
        2. Run `kelp ext reload`, then `kelp ext list` — fix the manifest if it reports an error. `kelp shot` writes the open
           window to a PNG and prints where, to see it as the user does.
        3. Tell the user where it appears (right inspector icon for panels, the + menu for tabs) and how to use it.
        4. If they want to share it, open a pull request to the library ("The library" below).

        Never use Claude Code plugins, mods, hooks or MCP for this: Kelp only loads its own extension folders.

        ---


        """
    }

    private static let terminalsGuide = """
        # Running commands in Kelp tabs

        This session runs inside Kelp and the `kelp` CLI is on PATH. Tests, builds and servers go in a tab of this
        workspace, where the user sees them and can run them again; quick commands (git status, ls) stay in your shell.

        - `kelp session new --cmd "swift test" --split down --wait` — a tab below yours runs it; prints the tab's session
          id, then exits with the command's exit code when it ends.
        - `kelp session new --cmd "npm run dev" --split down` — something that keeps running; prints the session (`id`).
        - `kelp terminal read <id> [bytes]` — what the tab printed (the last 8 KB), e.g. which tests failed.
        - `kelp wait <id> [--for done,waiting,idle,exited] [--timeout 10m]` — until it stops working, or reaches one of
          those; prints the state, and exits with the command's exit code once it ended.
        - `kelp report working "Migrating table 3 of 10" --progress 30` — on a long multi-step task, what you're doing
          and how far you got show on your row; `kelp report clear` takes it away. That you finished or ask something
          already shows by itself.

        """

    private static func put(_ name: String, on: Bool, description: String, body: String) {
        let plugin = Paths.agentSkills.appendingPathComponent(name)
        guard on else { try? FileManager.default.removeItem(at: plugin); return }
        let manifest: [String: Any] = ["name": name, "version": "1.0.0", "description": description, "author": ["name": "Kelp"]]
        if let d = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]), let json = String(bytes: d, encoding: .utf8) {
            writeIfChanged(plugin.appendingPathComponent(".claude-plugin/plugin.json"), json)
        }
        let front = "---\nname: \(name)\ndescription: \(description)\n---\n\n"
        writeIfChanged(plugin.appendingPathComponent("skills/\(name)/SKILL.md"), front + body)
    }

    private static func writeIfChanged(_ url: URL, _ text: String) {
        guard (try? String(contentsOf: url, encoding: .utf8)) != text else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Every setting the installed extensions declare, with how to change it.
    static func settingsGuide(_ app: AppModel) -> String {
        var out = """
        # Kelp settings

        Kelp keeps its settings in `$KELP_HOME/settings.json` (one flat object with dotted keys). Change them with the
        `kelp` CLI, which is on PATH in every Kelp session; the app applies changes immediately.

        - `kelp settings` — all current values
        - `kelp settings get <key>`
        - `kelp settings set <key> <value>` — the value is JSON when it parses (`true`, `14`, `["a"]`), else text
        - `kelp settings unset <key>` — back to the default
        - `kelp ext list` / `kelp ext enable <id>` / `kelp ext disable <id>` — turn extensions on or off

        Keyboard shortcuts are the `keys` object, laid over Kelp's defaults: command id → key, e.g.
        `{"editor.saveAll": "opt+cmd+s", "terminal.new": ""}` (`""` = no shortcut; macOS's own items such as Copy go by
        English menu path, `"Edit › Copy"`). Every command id is in `kelp ui state` (`commands`), and `kelp run <id>` runs one.
        `kelp settings set keys` replaces the whole object: keep the entries already there.

        Only change what the user asked for, then say what you changed.

        ## Keys

        | Key | Type | Default | What it does |
        | --- | --- | --- | --- |

        """
        for section in app.extensions.all.settings {
            for spec in section.specs {
                var type = spec.type
                if let o = spec.options, !o.isEmpty { type += ": " + o.joined(separator: " / ") }
                let def = spec.default.map { v -> String in
                    if case .string(let s) = v { return s.isEmpty ? "—" : s }
                    return (try? JSONEncoder().encode(v)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "—"
                } ?? "—"
                let what = [spec.title, spec.description].compactMap { $0 }.joined(separator: ". ").replacingOccurrences(of: "|", with: "/")
                out += "| `\(spec.key)` | \(type) | \(def) | \(what) |\n"
            }
        }
        out += "\nThemes for `workbench.theme`: auto, ghostty, " + app.themes.themes.map(\.id).joined(separator: ", ") + ".\n"
        out += "File icon themes for `workbench.iconTheme`: " + app.fileIcons.themes.map(\.id).joined(separator: ", ") + ".\n"
        return out
    }
}
