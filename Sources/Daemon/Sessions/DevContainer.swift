import Agents
import Core
import Foundation

/// A project the user runs in its dev container (its menu's Run in Dev Container, `Repo.devContainerKey`): its
/// terminals and agents start in the container its `.devcontainer/devcontainer.json` describes, through the Dev
/// Containers CLI and docker (or what stands in for it: OrbStack, Colima, Podman). The folder is bind-mounted at its
/// own path, and so are the project's main folder (a worktree's `.git` names it) and what an agent's command line
/// names of Kelp's: what they print, change and run is this Mac's folder, and git, turns and the editor read it here
/// as ever. The first start brings the container up (`devcontainer up`, its log in that terminal); later ones find
/// it. The agent's Environment settings and secrets go in by name (`docker exec -e NAME`): never on a command line.
enum DevContainer {
    /// Whether `folder` has a dev container: without one its project's terminals run here.
    static func configured(in folder: String) -> Bool {
        [".devcontainer/devcontainer.json", ".devcontainer.json"].contains {
            FileManager.default.fileExists(atPath: folder + "/" + $0)
        }
    }

    /// `argv` as it runs in the container: a terminal's login shell is the container's (bash, else sh), a command line
    /// goes to sh (it may have no zsh), and Claude-style hooks are the ones that report through the terminal.
    static func inside(_ argv: [String], _ manifest: AgentManifest) throws -> [String] {
        if manifest.id == "shell" {
            return ["sh", "-c", "if command -v bash >/dev/null 2>&1; then exec bash -l; else exec sh -l; fi"]
        }
        if manifest.id == "custom", argv.count == 3, argv[1] == "-lc" { return ["sh", "-lc", argv[2]] }
        var run = argv
        if case .settingsFlag(let flag)? = manifest.hooks {
            if let at = run.firstIndex(of: flag), at + 1 < run.count {
                run[at + 1] = try Hooks.containerSettingsJSON()
            } else {
                run += [flag, try Hooks.containerSettingsJSON()]
            }
        }
        return run
    }

    /// Kelp's folders `argv` names (a plugin dir, an MCP config), mounted read-only where they are.
    static func named(in argv: [String]) -> [String] {
        zip(argv, argv.dropFirst()).compactMap { flag, value in
            guard ["--plugin-dir", "--mcp-config"].contains(flag), value.hasPrefix("/") else { return nil }
            return flag == "--mcp-config" ? (value as NSString).deletingLastPathComponent : value
        }
    }

    /// `run` in `folder`'s container, at `cwd`: sh brings it up when it isn't (its log on screen), else quietly finds
    /// it, then `docker exec` with `env`'s names.
    static func wrap(
        _ run: [String], cwd: String, in box: (folder: String, project: String), readOnly: [String], env: [String]
    ) -> [String] {
        let (folder, project) = box
        let q = ShellQuote.word
        let mounts =
            ([folder, project].reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .map { "type=bind,source=\($0),target=\($0)" }
            + readOnly.map { "type=bind,source=\($0),target=\($0),readonly" })
            .flatMap { ["--mount", $0] }
        let up = (["devcontainer", "up", "--workspace-folder", folder] + mounts).map(q).joined(separator: " ")
        let names = (env + ["TERM"]).sorted().flatMap { ["-e", $0] }.map(q).joined(separator: " ")
        let missing = "Kelp: this project runs in its dev container, and"
        let script = """
            if ! command -v devcontainer >/dev/null 2>&1; then
              echo "\(missing) the Dev Containers CLI isn't installed: npm install -g @devcontainers/cli"
              exit 127
            fi
            if ! command -v docker >/dev/null 2>&1; then
              echo "\(missing) docker isn't here: install OrbStack, Colima or Docker Desktop."
              exit 127
            fi
            if docker ps -q --filter label=devcontainer.local_folder=\(q(folder)) 2>/dev/null | grep -q .; then
              out=$(\(up) 2>/dev/null)
            else
              echo "Starting the dev container…"
              out=$(\(up))
            fi
            id=$(printf %s "$out" | sed -n 's/.*"containerId" *: *"\\([^"]*\\)".*/\\1/p' | tail -n 1)
            user=$(printf %s "$out" | sed -n 's/.*"remoteUser" *: *"\\([^"]*\\)".*/\\1/p' | tail -n 1)
            if [ -z "$id" ]; then
              printf '%s\\n' "$out"
              echo "Kelp: the dev container didn't start."
              exit 1
            fi
            t=
            [ -t 0 ] && t=-t
            exec docker exec -i $t ${user:+-u "$user"} -w \(q(cwd)) \(names) "$id" "$@"
            """
        return ["/bin/sh", "-c", script, "sh"] + run
    }
}
