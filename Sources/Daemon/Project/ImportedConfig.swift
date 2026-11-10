import Core
import Foundation

/// A project another tool set up first. Without a .kelp.yaml, Kelp reads that tool's file for the same things: the setup a
/// new worktree gets, run / test and named commands, and the teardown, which becomes the `archive` command. So a project
/// coming from Conductor, Codex, Cursor and the like works from its first worktree. It's trusted like a .kelp.yaml
/// (`configAndTrust`), and the question names the file. The scripts expect their tool's variables (the main checkout, the
/// worktree, its name, a port): those are set from Kelp's (`prelude`).
/// Limits: Kelp doesn't run `archive` by itself when a workspace goes, it's a command to run by hand; a tool's personal
/// override file (`settings.local.toml`, `config.local.json`) and Orca's orca.yaml are left out.
enum ImportedConfig {
    typealias Reader = @Sendable (_ text: String, _ root: String) -> RepoConfig?

    /// In this order when a project has several; a tool's current file before its older one.
    static let sources: [(file: String, read: Reader)] = [
        (".conductor/settings.toml", conductorTOML), ("conductor.json", conductorJSON),
        (".codex/environments/environment.toml", codex),
        (".cursor/worktrees.json", cursor),
        (".paradev/config.json", superset), (".superset/config.json", superset),
        (".emdash.json", emdash), (".air/worktree.json", air), ("supacode.json", supacode),
        (".cmux/cmux.json", cmux), ("cmux.json", cmux)
    ]

    /// The first of them the project has that names anything: its path in the project, its text, what Kelp makes of it.
    static func find(_ root: String) -> (file: String, text: String, config: RepoConfig)? {
        for source in sources {
            for file in source.file.hasPrefix(".codex/") ? codexFiles(root) : [source.file] {
                guard let data = FileManager.default.contents(atPath: root + "/" + file),
                    let text = String(data: data, encoding: .utf8),
                    let config = source.read(text, root), !Workspaces.asksNothing(config)
                else { continue }
                return (file, text, config)
            }
        }
        return nil
    }

    /// Codex keeps one file per environment: environment.toml first, then the others by name.
    static func codexFiles(_ root: String) -> [String] {
        let dir = ".codex/environments"
        let all: [String] = FileManager.default.enumerator(atPath: root + "/" + dir)?.allObjects as? [String] ?? []
        let names = all.filter { $0.hasSuffix(".toml") && !$0.contains("/") }.sorted()
        return (names.filter { $0 == "environment.toml" } + names.filter { $0 != "environment.toml" }).map {
            dir + "/" + $0
        }
    }

    // MARK: the tools

    static func conductorTOML(_ text: String, _ root: String) -> RepoConfig? {
        let toml = MiniTOML(text)
        var config = RepoConfig()
        config.setup = toml.string("scripts.setup")
        if let run = toml.string("scripts.run") { add(&config, "run", run) }
        let ids = toml.names(under: "scripts.run.")
        let main = ids.first { toml.bool("scripts.run.\($0).default") } ?? (ids.count == 1 ? ids.first : nil)
        for id in ids {
            let key = "scripts.run.\(id)."
            guard var cmd = toml.string(key + "command") else { continue }
            if let args = toml.strings(key + "args"), !args.isEmpty {
                cmd += " " + args.map(ShellQuote.word).joined(separator: " ")
            }
            if let cwd = toml.string(key + "options.cwd") { cmd = "cd \(ShellQuote.word(cwd)) && \(cmd)" }
            add(&config, id == main ? "run" : id, cmd)
        }
        add(&config, "archive", toml.string("scripts.archive"))
        return finish(config, conductorVars(root))
    }

    static func conductorJSON(_ text: String, _ root: String) -> RepoConfig? {
        guard let scripts = JSONC.object(text)?["scripts"] as? [String: Any] else { return nil }
        var config = RepoConfig()
        config.setup = steps(scripts["setup"])
        add(&config, "run", steps(scripts["run"]))
        add(&config, "archive", steps(scripts["archive"]))
        return finish(config, conductorVars(root))
    }

    static func conductorVars(_ root: String) -> [(String, String)] {
        [
            ("CONDUCTOR_ROOT_PATH", ShellQuote.word(root)), ("CONDUCTOR_WORKSPACE_PATH", here),
            ("CONDUCTOR_WORKSPACE_NAME", name), ("CONDUCTOR_PORT", port)
        ]
    }

    /// Codex's local environment: setup (its macOS one first), cleanup, and actions (`icon = "run"` / `"test"` are those).
    static func codex(_ text: String, _ root: String) -> RepoConfig? {
        let toml = MiniTOML(text)
        var config = RepoConfig()
        config.setup = toml.string("setup.darwin.script") ?? toml.string("setup.script")
        for action in toml.names(under: "actions.") {
            let key = "actions.\(action)."
            guard let cmd = toml.string(key + "command"), ["darwin", nil].contains(toml.string(key + "platform")) else {
                continue
            }
            let icon = toml.string(key + "icon") ?? ""
            add(
                &config,
                ["run", "test"].contains(icon) && !config.scripts.contains { $0.name == icon }
                    ? icon : toml.string(key + "name") ?? icon, cmd)
        }
        add(&config, "archive", toml.string("cleanup.darwin.script") ?? toml.string("cleanup.script"))
        return finish(config, [("CODEX_SOURCE_TREE_PATH", ShellQuote.word(root)), ("CODEX_WORKTREE_PATH", here)])
    }

    /// Cursor: a list of commands, or a script's path (from .cursor/), its Unix one first.
    static func cursor(_ text: String, _ root: String) -> RepoConfig? {
        guard let json = JSONC.object(text) else { return nil }
        var config = RepoConfig()
        switch json["setup-worktree-unix"] ?? json["setup-worktree"] {
        case let path as String: config.setup = "bash " + ShellQuote.word(root + "/.cursor/" + path)
        case let list: config.setup = steps(list)
        }
        return finish(config, [("ROOT_WORKTREE_PATH", ShellQuote.word(root))])
    }

    /// Superset (now Paradev): lists of commands.
    static func superset(_ text: String, _ root: String) -> RepoConfig? {
        guard let json = JSONC.object(text) else { return nil }
        var config = RepoConfig()
        config.setup = steps(json["setup"])
        add(&config, "run", steps(json["run"]))
        add(&config, "archive", steps(json["teardown"]))
        return finish(
            config,
            [
                ("SUPERSET_ROOT_PATH", ShellQuote.word(root)), ("SUPERSET_WORKSPACE_PATH", here),
                ("SUPERSET_WORKSPACE_NAME", name)
            ])
    }

    static func emdash(_ text: String, _ root: String) -> RepoConfig? {
        guard let scripts = JSONC.object(text)?["scripts"] as? [String: Any] else { return nil }
        var config = RepoConfig()
        config.setup = steps([scripts["prepare"], scripts["setup"]].compactMap { $0 as? String })
        add(&config, "run", steps(scripts["run"]))
        add(&config, "archive", steps(scripts["teardown"]))
        return finish(config, [("EMDASH_TASK_PATH", here), ("EMDASH_TASK_NAME", name), ("EMDASH_PORT", port)])
    }

    /// JetBrains Air: each step's macOS commands.
    static func air(_ text: String, _ root: String) -> RepoConfig? {
        guard let json = JSONC.object(text) else { return nil }
        let mac = { (value: Any?) in (value as? [String: Any])?["macos"] ?? value }
        var config = RepoConfig()
        config.setup = steps(mac(json["setup"]))
        add(&config, "archive", steps(mac(json["cleanup"])))
        return finish(config, [])
    }

    /// Supacode: its scripts by kind (run, test, lint are Kelp's own names).
    static func supacode(_ text: String, _ root: String) -> RepoConfig? {
        guard let json = JSONC.object(text) else { return nil }
        var config = RepoConfig()
        config.setup = steps(json["setupScript"])
        add(&config, "run", steps(json["runScript"]))
        for script in json["scripts"] as? [[String: Any]] ?? [] {
            let kind = script["kind"] as? String ?? ""
            add(
                &config, RepoConfig.scriptNames.contains(kind) ? kind : script["name"] as? String ?? kind,
                steps(script["command"]))
        }
        add(&config, "archive", steps(json["archiveScript"]) ?? steps(json["deleteScript"]))
        return finish(config, [("SUPACODE_ROOT_PATH", ShellQuote.word(root)), ("SUPACODE_WORKTREE_PATH", here)])
    }

    /// cmux: its command palette's commands; one named "setup" is the setup.
    static func cmux(_ text: String, _ root: String) -> RepoConfig? {
        guard let list = JSONC.object(text)?["commands"] as? [[String: Any]] else { return nil }
        var config = RepoConfig()
        for cmd in list {
            guard let name = cmd["name"] as? String, let command = steps(cmd["command"]) else { continue }
            if name.lowercased() == "setup", config.setup == nil {
                config.setup = command
            } else {
                add(&config, name, command)
            }
        }
        return finish(config, [])
    }

    // MARK: helpers

    static let here = "\"$PWD\"", name = "\"${PWD##*/}\"", port = "\"$KELP_PORT\""

    /// A command, or a list of them run in turn that stops at the first to fail (as those tools run them). Empty: none.
    static func steps(_ value: Any?) -> String? {
        let list = (value as? [String] ?? (value as? String).map { [$0] } ?? []).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return list.isEmpty ? nil : list.count == 1 ? list[0] : "set -e\n" + list.joined(separator: "\n")
    }

    static func add(_ config: inout RepoConfig, _ name: String, _ command: String?) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard let command = command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty, !name.isEmpty,
            !config.scripts.contains(where: { $0.name == name })
        else { return }
        config.scripts.append(.init(name: name, command: command))
    }

    static func finish(_ config: RepoConfig, _ vars: [(String, String)]) -> RepoConfig {
        var config = config
        config.setup = steps(config.setup)
        if !vars.isEmpty { config.prelude = "export " + vars.map { "\($0.0)=\($0.1)" }.joined(separator: " ") + "\n" }
        return config
    }
}
