import Foundation

/// How an agent reports its own status to Kelp. Agent files keep the flat keys they always had (`hooksSettingsFlag`…).
public enum HookTransport: Sendable, Equatable {
    /// `{flag} <file>` on its command line; the file holds Claude Code-style hooks (`Hooks.settingsJSON`).
    case settingsFlag(String)
    /// An OpenCode-style config dir in `{env}` with Kelp's plugin in it (Kilo Code, OpenCode); its own dir is still read.
    case pluginDir(env: String)
    /// The same hooks file in `{env}`, standing in for the file it names by default (`replaces`), whose settings it
    /// carries over: Qwen Code's system settings are an admin's policy.
    case settingsFile(env: String, replaces: String?)
    /// herdr's socket (fx): `HERDR_SOCKET_PATH` is kelpd's, `HERDR_PANE_ID` the session (`pane.report_agent`).
    case herdr

    /// The variable it's set through, if any.
    public var env: String? {
        switch self {
        case .pluginDir(let e), .settingsFile(let e, _): e
        case .settingsFlag, .herdr: nil
        }
    }

    init?(from c: KeyedDecodingContainer<AgentManifest.CodingKeys>) throws {
        if let f = try c.decodeIfPresent(String.self, forKey: .hooksSettingsFlag) {
            self = .settingsFlag(f)
        } else if let e = try c.decodeIfPresent(String.self, forKey: .hooksConfigDirEnv) {
            self = .pluginDir(env: e)
        } else if let e = try c.decodeIfPresent(String.self, forKey: .hooksSettingsEnv) {
            self = .settingsFile(
                env: e,
                replaces: AgentManifest.presets.lazy.compactMap { p -> String? in
                    if case .settingsFile(e, let r)? = p.hooks { return r }
                    return nil
                }.first)
        } else if try c.decodeIfPresent(Bool.self, forKey: .hooksHerdr) == true {
            self = .herdr
        } else {
            return nil
        }
    }

    func encode(to c: inout KeyedEncodingContainer<AgentManifest.CodingKeys>) throws {
        switch self {
        case .settingsFlag(let f): try c.encode(f, forKey: .hooksSettingsFlag)
        case .pluginDir(let e): try c.encode(e, forKey: .hooksConfigDirEnv)
        case .settingsFile(let e, _): try c.encode(e, forKey: .hooksSettingsEnv)
        case .herdr: try c.encode(true, forKey: .hooksHerdr)
        }
    }
}
