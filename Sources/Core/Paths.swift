import Foundation

public enum Paths {
    public static var root: URL {
        let stable = home.appendingPathComponent(".kelp")
        // Kelp Nightly and Kelp Dev name a home of their own (KelpHome, scripts/bundle.sh); so does any debug build.
        #if DEBUG
        let own: URL? = home.appendingPathComponent(".kelp-dev")
        #else
        let own = (Bundle.main.object(forInfoDictionaryKey: "KelpHome") as? String).map { home.appendingPathComponent($0) }
        #endif
        // KELP_HOME picks another (tests, snapshots), but never Kelp's own for a build with its own home: one started from a
        // Kelp terminal inherits it (`open` passes the shell's on), and would restart that kelpd, ending its agents.
        if let e = ProcessInfo.processInfo.environment["KELP_HOME"].map({ URL(fileURLWithPath: $0) }),
           own == nil || e.standardizedFileURL.path != stable.path { return e }
        return own ?? stable
    }
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    public static var socket: URL { root.appendingPathComponent("kelp.sock") }
    public static var agents: URL { root.appendingPathComponent("agents") }
    public static var extensions: URL { root.appendingPathComponent("extensions") }
    /// Claude Code plugins with Kelp's skills (one per skill that's turned on), loaded per session with --plugin-dir.
    public static var agentSkills: URL { root.appendingPathComponent("agent-skills") }
    /// A folder of its own for agents and terminals outside any project (Window › Scratch); not listed with the projects.
    public static var scratch: URL { root.appendingPathComponent("scratch") }
    /// Why kelpd last failed to start (written by kelpd, gone once one starts): what the app's banner says.
    public static func daemonError(in root: URL) -> URL { root.appendingPathComponent("kelpd.err") }

    public static func ensure(_ u: URL) throws {
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    }

    /// `path` with its symlinks resolved, "/private" kept (/tmp → /private/tmp; resolvingSymlinksInPath strips it).
    /// Nil when it isn't there.
    public static func real(_ path: String) -> String? { realpath(path, nil).map { p in defer { free(p) }; return String(cString: p) } }
}
