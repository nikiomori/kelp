import Agents
import Core
import Foundation
import os

/// How Kelp starts OpenCode 2 (2026-11). OpenCode 2 runs its sessions in one background server that every terminal
/// shares; the server starts with the environment of the first terminal (its `KELP_SESSION` and `KELP_PORT`), and
/// `OPENCODE_CONFIG_DIR` replaces the person's own config there (version 1 read both). So Kelp gives each session a
/// server of its own (`--standalone`), puts the session's model in that server's config (`OPENCODE_CONFIG_CONTENT`,
/// layered over the person's own, since the terminal UI has no `-m`), and adds Kelp's status plugin through the
/// terminal UI's config (`OPENCODE_CLI_CONFIG_CONTENT`), keeping the person's own plugins.
final class OpenCode2: Sendable {
    static let standalone = "--standalone"
    static let cliConfig = "OPENCODE_CLI_CONFIG_CONTENT"
    static let serverConfig = "OPENCODE_CONFIG_CONTENT"
    private let known = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])

    /// Whether `argv` starts OpenCode 2 or later: asked once per binary (`--version`, about 40 ms).
    func runs(_ argv: [String]) -> Bool {
        guard let exe = argv.first else { return false }
        let path: String
        do { path = try LoginPath.resolve(exe) } catch { return false }
        let id = CodexHookCheck.fingerprint(path)
        if let answer = known.withLock({ $0[id] }) { return answer }
        let printed = Log.session.attempt("asking \(path) its version") {
            try Subprocess.output([path, "--version"], cwd: "/", timeLimit: 5)
        }
        let answer = Self.major(String(decoding: printed ?? Data(), as: UTF8.self)) >= 2
        known.withLock { $0[id] = answer }
        return answer
    }

    /// The major version: the first number of the last word ("opencode v2.2.7" or "1.17.11").
    static func major(_ version: String) -> Int {
        let word = version.split(whereSeparator: \.isWhitespace).last ?? ""
        return Int(word.drop { !$0.isNumber }.prefix { $0.isNumber }) ?? 0
    }

    /// Adds `--standalone`, so the session gets its own server, and takes out `-m <model>`, which the terminal UI would
    /// refuse to start with. The model goes into config instead, which the session's own server reads from the
    /// environment. The config is nil without a model.
    static func argv(_ argv: [String]) -> (argv: [String], config: String?) {
        var out: [String] = []
        var model: String?
        var index = argv.startIndex
        while index < argv.endIndex {
            let arg = argv[index]
            if arg == "-m" || arg == "--model", index + 1 < argv.endIndex {
                model = argv[index + 1]
                index += 1
            } else if arg.hasPrefix("--model=") {
                model = String(arg.dropFirst("--model=".count))
            } else {
                out.append(arg)
            }
            index += 1
        }
        if !out.contains(standalone) { out.insert(standalone, at: min(1, out.count)) }
        let config = model.flatMap { model in
            Log.session.attempt("writing OpenCode's model") {
                String(decoding: try JSONSerialization.data(withJSONObject: ["model": model]), as: UTF8.self)
            }
        }
        return (out, config)
    }

    /// The terminal UI's config, with Kelp's plugin added after the person's own plugins (a plugin list given here
    /// replaces theirs). `config` is their config folder. Their file is `cli.json`, or `tui.json(c)` before OpenCode 2
    /// first ran and migrated it.
    static func cliConfig(plugin: URL, config: URL) -> String {
        func read(_ name: String) -> [String: Any]? {
            FileManager.default.contents(atPath: config.appendingPathComponent(name).path)
                .flatMap { JSONC.object(String(decoding: $0, as: UTF8.self)) }
        }
        var plugins: [Any]
        if let cli = read("cli.json") {
            plugins = cli["plugins"] as? [Any] ?? []
        } else {
            let legacy = read("tui.jsonc") ?? read("tui.json")
            plugins = (legacy?["plugin"] as? [Any] ?? []).map { entry in
                guard let pair = entry as? [Any], let name = pair.first else { return entry }
                return ["package": name, "options": pair.count > 1 ? pair[1] : [:]]
            }
        }
        plugins.append(plugin.path)
        let data = Log.session.attempt("writing OpenCode's plugin list") {
            try JSONSerialization.data(withJSONObject: ["plugins": plugins], options: .withoutEscapingSlashes)
        }
        return String(decoding: data ?? Data(), as: UTF8.self)
    }

    /// The person's OpenCode config dir.
    static func configDir(_ env: [String: String]) -> URL {
        let all = ProcessInfo.processInfo.environment.merging(env) { $1 }
        if let dir = all["OPENCODE_CONFIG_DIR"] { return URL(fileURLWithPath: dir) }
        let base =
            all["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("opencode")
    }
}
