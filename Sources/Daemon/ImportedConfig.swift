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
        for s in sources {
            for file in s.file.hasPrefix(".codex/") ? codexFiles(root) : [s.file] {
                guard let data = FileManager.default.contents(atPath: root + "/" + file),
                    let text = String(data: data, encoding: .utf8),
                    let c = s.read(text, root), !Workspaces.asksNothing(c)
                else { continue }
                return (file, text, c)
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
        let t = MiniTOML(text)
        var c = RepoConfig()
        c.setup = t.string("scripts.setup")
        if let run = t.string("scripts.run") { add(&c, "run", run) }
        let ids = t.names(under: "scripts.run.")
        let main = ids.first { t.bool("scripts.run.\($0).default") } ?? (ids.count == 1 ? ids.first : nil)
        for id in ids {
            let k = "scripts.run.\(id)."
            guard var cmd = t.string(k + "command") else { continue }
            if let args = t.strings(k + "args"), !args.isEmpty {
                cmd += " " + args.map(IDE.shellWord).joined(separator: " ")
            }
            if let cwd = t.string(k + "options.cwd") { cmd = "cd \(IDE.shellWord(cwd)) && \(cmd)" }
            add(&c, id == main ? "run" : id, cmd)
        }
        add(&c, "archive", t.string("scripts.archive"))
        return finish(c, conductorVars(root))
    }

    static func conductorJSON(_ text: String, _ root: String) -> RepoConfig? {
        guard let s = JSONC.object(text)?["scripts"] as? [String: Any] else { return nil }
        var c = RepoConfig()
        c.setup = steps(s["setup"])
        add(&c, "run", steps(s["run"]))
        add(&c, "archive", steps(s["archive"]))
        return finish(c, conductorVars(root))
    }

    static func conductorVars(_ root: String) -> [(String, String)] {
        [
            ("CONDUCTOR_ROOT_PATH", IDE.shellWord(root)), ("CONDUCTOR_WORKSPACE_PATH", here),
            ("CONDUCTOR_WORKSPACE_NAME", name), ("CONDUCTOR_PORT", port)
        ]
    }

    /// Codex's local environment: setup (its macOS one first), cleanup, and actions (`icon = "run"` / `"test"` are those).
    static func codex(_ text: String, _ root: String) -> RepoConfig? {
        let t = MiniTOML(text)
        var c = RepoConfig()
        c.setup = t.string("setup.darwin.script") ?? t.string("setup.script")
        for i in t.names(under: "actions.") {
            let k = "actions.\(i)."
            guard let cmd = t.string(k + "command"), ["darwin", nil].contains(t.string(k + "platform")) else {
                continue
            }
            let icon = t.string(k + "icon") ?? ""
            add(
                &c,
                ["run", "test"].contains(icon) && !c.scripts.contains { $0.name == icon }
                    ? icon : t.string(k + "name") ?? icon, cmd)
        }
        add(&c, "archive", t.string("cleanup.darwin.script") ?? t.string("cleanup.script"))
        return finish(c, [("CODEX_SOURCE_TREE_PATH", IDE.shellWord(root)), ("CODEX_WORKTREE_PATH", here)])
    }

    /// Cursor: a list of commands, or a script's path (from .cursor/), its Unix one first.
    static func cursor(_ text: String, _ root: String) -> RepoConfig? {
        guard let j = JSONC.object(text) else { return nil }
        var c = RepoConfig()
        switch j["setup-worktree-unix"] ?? j["setup-worktree"] {
        case let path as String: c.setup = "bash " + IDE.shellWord(root + "/.cursor/" + path)
        case let list: c.setup = steps(list)
        }
        return finish(c, [("ROOT_WORKTREE_PATH", IDE.shellWord(root))])
    }

    /// Superset (now Paradev): lists of commands.
    static func superset(_ text: String, _ root: String) -> RepoConfig? {
        guard let j = JSONC.object(text) else { return nil }
        var c = RepoConfig()
        c.setup = steps(j["setup"])
        add(&c, "run", steps(j["run"]))
        add(&c, "archive", steps(j["teardown"]))
        return finish(
            c,
            [
                ("SUPERSET_ROOT_PATH", IDE.shellWord(root)), ("SUPERSET_WORKSPACE_PATH", here),
                ("SUPERSET_WORKSPACE_NAME", name)
            ])
    }

    static func emdash(_ text: String, _ root: String) -> RepoConfig? {
        guard let s = JSONC.object(text)?["scripts"] as? [String: Any] else { return nil }
        var c = RepoConfig()
        c.setup = steps([s["prepare"], s["setup"]].compactMap { $0 as? String })
        add(&c, "run", steps(s["run"]))
        add(&c, "archive", steps(s["teardown"]))
        return finish(c, [("EMDASH_TASK_PATH", here), ("EMDASH_TASK_NAME", name), ("EMDASH_PORT", port)])
    }

    /// JetBrains Air: each step's macOS commands.
    static func air(_ text: String, _ root: String) -> RepoConfig? {
        guard let j = JSONC.object(text) else { return nil }
        let mac = { (v: Any?) in (v as? [String: Any])?["macos"] ?? v }
        var c = RepoConfig()
        c.setup = steps(mac(j["setup"]))
        add(&c, "archive", steps(mac(j["cleanup"])))
        return finish(c, [])
    }

    /// Supacode: its scripts by kind (run, test, lint are Kelp's own names).
    static func supacode(_ text: String, _ root: String) -> RepoConfig? {
        guard let j = JSONC.object(text) else { return nil }
        var c = RepoConfig()
        c.setup = steps(j["setupScript"])
        add(&c, "run", steps(j["runScript"]))
        for s in j["scripts"] as? [[String: Any]] ?? [] {
            let kind = s["kind"] as? String ?? ""
            add(&c, RepoConfig.scriptNames.contains(kind) ? kind : s["name"] as? String ?? kind, steps(s["command"]))
        }
        add(&c, "archive", steps(j["archiveScript"]) ?? steps(j["deleteScript"]))
        return finish(c, [("SUPACODE_ROOT_PATH", IDE.shellWord(root)), ("SUPACODE_WORKTREE_PATH", here)])
    }

    /// cmux: its command palette's commands; one named "setup" is the setup.
    static func cmux(_ text: String, _ root: String) -> RepoConfig? {
        guard let list = JSONC.object(text)?["commands"] as? [[String: Any]] else { return nil }
        var c = RepoConfig()
        for cmd in list {
            guard let name = cmd["name"] as? String, let command = steps(cmd["command"]) else { continue }
            if name.lowercased() == "setup", c.setup == nil { c.setup = command } else { add(&c, name, command) }
        }
        return finish(c, [])
    }

    // MARK: helpers

    static let here = "\"$PWD\"", name = "\"${PWD##*/}\"", port = "\"$KELP_PORT\""

    /// A command, or a list of them run in turn that stops at the first to fail (as those tools run them). Empty: none.
    static func steps(_ v: Any?) -> String? {
        let list = (v as? [String] ?? (v as? String).map { [$0] } ?? []).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return list.isEmpty ? nil : list.count == 1 ? list[0] : "set -e\n" + list.joined(separator: "\n")
    }

    static func add(_ c: inout RepoConfig, _ name: String, _ command: String?) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard let command = command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty, !name.isEmpty,
            !c.scripts.contains(where: { $0.name == name })
        else { return }
        c.scripts.append(.init(name: name, command: command))
    }

    static func finish(_ c: RepoConfig, _ vars: [(String, String)]) -> RepoConfig {
        var c = c
        c.setup = steps(c.setup)
        if !vars.isEmpty { c.prelude = "export " + vars.map { "\($0.0)=\($0.1)" }.joined(separator: " ") + "\n" }
        return c
    }
}
