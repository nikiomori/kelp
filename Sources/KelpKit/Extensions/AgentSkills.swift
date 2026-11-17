import Core
import Foundation
import os

/// Kelp's skills for agents. Each is a Claude Code plugin in ~/.kelp/agent-skills that the daemon loads per session
/// (--plugin-dir): how to write and connect an extension, how to change settings (the shell's skill, made from what is
/// installed), and the built-ins' own skills (`Contributions.skills`). Turning a skill off in Settings › Agents removes
/// it, and so does turning off the built-in that provides it. Nothing is written to the agent's own config.
@MainActor
enum AgentSkills {
    /// Logs each skill that couldn't be written or removed, because otherwise an agent would go on with an old skill,
    /// or none, and nobody would see why.
    private nonisolated static let log = Logger.kelp("skills")

    static func write(_ app: AppModel) {
        // Write nothing before the extensions are loaded, because most skills come from them and the settings guide
        // lists their rows.
        guard !app.extensions.extensions.isEmpty else { return }
        let settings = app.settings
        let skills =
            [
                SkillSpec(
                    name: "kelp-extensions",
                    description:
                        "Use when the user wants something added to or changed in Kelp, the IDE this session runs in: a panel, list, tab, command, "
                        + "setting, theme or language server — e.g. “add a Kelp panel with my Docker containers”, “show Android emulators in Kelp”. Kelp extensions are "
                        + "extension.json folders in $KELP_HOME/extensions; they are not Claude Code plugins, mods, hooks or MCP servers.",
                    setting: SettingKeys.skillExtensions,
                    body: extensionsSteps(ExtensionRegistry.userDir.path) + ExtensionFiles.extensionGuide),
                SkillSpec(
                    name: "kelp-settings",
                    description:
                        "Use when the user wants to see or change how Kelp, the IDE this session runs in, is set up: theme, fonts, editor, "
                        + "terminal, agents. Done with the kelp CLI (kelp settings set …), not Claude Code's own settings.",
                    setting: SettingKeys.skillSettings, body: settingsGuide(app))
            ] + app.extensions.all.skills
        let wanted = skills.map {
            (name: $0.name, on: $0.setting.map { settings[$0] } ?? true, description: $0.description, body: $0.body)
        }
        let guideDir = ExtensionRegistry.userDir
        // The writes run off the main thread, one after another in the order they were asked for.
        files.async {
            for skill in wanted { put(skill.name, on: skill.on, description: skill.description, body: skill.body) }
            // Remove the folder of each skill that no extension gives now (its built-in was turned off, or it has the
            // `krill-` prefix of the app's old name).
            let given = Set(wanted.map(\.name))
            let folders = FileManager.default.enumerator(atPath: Paths.agentSkills.path)
            while let old = folders?.nextObject() as? String {
                folders?.skipDescendants()   // look at the plugins' own folders only
                guard old.hasPrefix("kelp-") || old.hasPrefix("krill-"), !given.contains(old) else { continue }
                put(old, on: false, description: "", body: "")
            }
            // The guide also sits next to the user's extensions, for people.
            log.attempt("writing the extension guide") { try ExtensionFiles.writeGuide(in: guideDir) }
        }
    }
    private nonisolated static let files = DispatchQueue(label: "kelp.agent-skills")

    /// The steps with the exact folder this Kelp loads extensions from, because the guide below says ~/.kelp and a
    /// custom KELP_HOME changes that.
    private static func extensionsSteps(_ folder: String) -> String {
        """
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

    private nonisolated static func put(_ name: String, on: Bool, description: String, body: String) {
        let plugin = Paths.agentSkills.appendingPathComponent(name)
        guard on else {
            guard FileManager.default.fileExists(atPath: plugin.path) else { return }
            log.attempt("removing the skill \(name)") { try FileManager.default.removeItem(at: plugin) }
            return
        }
        let manifest: [String: Any] = [
            "name": name, "version": "1.0.0", "description": description, "author": ["name": "Kelp"]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]),
            let json = String(bytes: data, encoding: .utf8)
        {
            writeIfChanged(plugin.appendingPathComponent(".claude-plugin/plugin.json"), json)
        }
        let front = "---\nname: \(name)\ndescription: \(description)\n---\n\n"
        writeIfChanged(plugin.appendingPathComponent("skills/\(name)/SKILL.md"), front + body)
    }

    private nonisolated static func writeIfChanged(_ url: URL, _ text: String) {
        guard (try? String(contentsOf: url, encoding: .utf8)) != text else { return }
        log.attempt("writing \(url.path.replacingOccurrences(of: Paths.agentSkills.path, with: "agent-skills"))") {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
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
            - `kelp ext list` — the extensions and which are on; turning one on or off is the user's (Settings › Extensions)

            Keyboard shortcuts are the user's to set, in Settings › Keyboard (the `keys` object, command id → key): say which
            command and key to pick. Every command id is in `kelp ui state` (`commands`), and `kelp run <id>` runs one.

            Only change what the user asked for, then say what you changed.

            ## Keys

            | Key | Type | Default | What it does |
            | --- | --- | --- | --- |

            """
        for section in app.extensions.all.settings {
            for spec in section.specs {
                var type = spec.type.name
                if let options = spec.options, !options.isEmpty { type += ": " + options.joined(separator: " / ") }
                let def = spec.default.map(ExtActions.text).flatMap { $0.isEmpty ? nil : $0 } ?? "—"
                let what = [spec.title, spec.description].compactMap { $0 }.joined(separator: ". ")
                    .replacingOccurrences(of: "|", with: "/")
                out += "| `\(spec.key)` | \(type) | \(def) | \(what) |\n"
            }
        }
        out +=
            "\nThemes for `workbench.theme`: auto, ghostty, " + app.themes.themes.map(\.id).joined(separator: ", ")
            + ".\n"
        out +=
            "File icon themes for `workbench.iconTheme`: " + app.fileIcons.themes.map(\.id).joined(separator: ", ")
            + ".\n"
        return out
    }
}
