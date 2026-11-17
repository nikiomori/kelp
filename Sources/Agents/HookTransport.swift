import Foundation

/// How an agent reports its own status to Kelp. Agent files keep the flat keys they always had (`hooksSettingsFlag`…).
public enum HookTransport: Sendable, Equatable {
    /// `{flag} <file>` on the agent's command line, where the file holds Claude Code-style hooks
    /// (`Hooks.settingsJSON`).
    case settingsFlag(String)
    /// An OpenCode-style config dir in `{env}` with Kelp's plugin in it (Kilo Code, OpenCode). The agent still reads
    /// its own config dir too. OpenCode 2 would read only that dir, so its terminal UI gets the plugin from the dir's
    /// `tui` folder instead.
    case pluginDir(env: String)
    /// The same hooks file, named in `{env}`. It stands in for the file the agent reads by default (`replaces`) and
    /// carries over that file's settings, because Qwen Code's system settings are an admin's policy.
    case settingsFile(env: String, replaces: String?)
    /// herdr's socket (fx). `HERDR_SOCKET_PATH` points at kelpd's socket, and `HERDR_PANE_ID` names the session
    /// (`pane.report_agent`).
    case herdr
    /// Codex gets the hooks and their trust on its command line (`-c`, `CodexHooks.args`), so nothing is written to
    /// ~/.codex.
    case codexConfig

    /// The environment variable that the transport is set through, if any.
    public var env: String? {
        switch self {
        case .pluginDir(let name), .settingsFile(let name, _): name
        case .settingsFlag, .herdr, .codexConfig: nil
        }
    }

    init?(from container: KeyedDecodingContainer<AgentManifest.CodingKeys>) throws {
        if let flag = try container.decodeIfPresent(String.self, forKey: .hooksSettingsFlag) {
            self = .settingsFlag(flag)
        } else if let name = try container.decodeIfPresent(String.self, forKey: .hooksConfigDirEnv) {
            self = .pluginDir(env: name)
        } else if let name = try container.decodeIfPresent(String.self, forKey: .hooksSettingsEnv) {
            self = .settingsFile(
                env: name,
                replaces: AgentManifest.presets.lazy.compactMap { preset -> String? in
                    if case .settingsFile(name, let replaced)? = preset.hooks { return replaced }
                    return nil
                }.first)
        } else if try container.decodeIfPresent(Bool.self, forKey: .hooksHerdr) == true {
            self = .herdr
        } else if try container.decodeIfPresent(Bool.self, forKey: .hooksCodexConfig) == true {
            self = .codexConfig
        } else {
            return nil
        }
    }

    func encode(to container: inout KeyedEncodingContainer<AgentManifest.CodingKeys>) throws {
        switch self {
        case .settingsFlag(let flag): try container.encode(flag, forKey: .hooksSettingsFlag)
        case .pluginDir(let name): try container.encode(name, forKey: .hooksConfigDirEnv)
        case .settingsFile(let name, _): try container.encode(name, forKey: .hooksSettingsEnv)
        case .herdr: try container.encode(true, forKey: .hooksHerdr)
        case .codexConfig: try container.encode(true, forKey: .hooksCodexConfig)
        }
    }
}
