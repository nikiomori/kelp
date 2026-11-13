import Foundation

public enum Paths {
    /// Read once: nothing sets KELP_HOME after launch (tests set it as their bundle loads), and this is read for every
    /// project name drawn, where reading the bundle's Info.plist each time held a workspace switch ~50 ms.
    public static let root: URL = {
        // KELP_HOME picks another (tests, snapshots), but never Kelp's own for a build with its own home: one started from a
        // Kelp terminal inherits it (`open` passes the shell's on), and would restart that kelpd, ending its agents.
        if let home = getenv("KELP_HOME").map({ URL(fileURLWithPath: String(cString: $0)) }),
            own == nil || home.standardizedFileURL.path != stable.path
        {
            return home
        }
        return own ?? stable
    }()
    /// Kelp's home, for a build running on a home of its own: what that home starts as (`HomeSeed`).
    public static var seed: URL? { own?.path == root.path ? stable : nil }
    private static var stable: URL { home.appendingPathComponent(".kelp") }
    /// Kelp Beta and Kelp Dev name a home of their own (KelpHome, scripts/bundle.sh); so does any debug build.
    private static let own: URL? = {
        #if DEBUG
            home.appendingPathComponent(".kelp-dev")
        #else
            (Bundle.main.object(forInfoDictionaryKey: "KelpHome") as? String).map { home.appendingPathComponent($0) }
        #endif
    }()
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    public static var socket: URL { root.appendingPathComponent("kelp.sock") }
    public static var agents: URL { root.appendingPathComponent("agents") }
    public static var extensions: URL { root.appendingPathComponent("extensions") }
    /// Claude Code plugins with Kelp's skills (one per skill that's turned on), loaded per session with --plugin-dir.
    public static var agentSkills: URL { root.appendingPathComponent("agent-skills") }
    /// A folder of its own for agents and terminals outside any project (Window › Scratch); not listed with the projects.
    public static var scratch: URL { root.appendingPathComponent("scratch") }
    /// Why kelpd last failed to start (written by kelpd, gone once one starts): what the app's banner says.
    public static func daemonError(in root: URL) -> URL { root.appendingPathComponent("kelpd.err") }

    public static func ensure(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// `path` with its symlinks resolved, "/private" kept (/tmp → /private/tmp; resolvingSymlinksInPath strips it).
    /// Nil when it isn't there.
    public static func real(_ path: String) -> String? {
        realpath(path, nil).map { resolved in
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    /// Whether `path` is `folder` or in it, both as they really are: `..` and links followed, a relative path taken from
    /// the current folder. So `/a/bc` isn't in `/a/b`, a link out of the folder isn't in it, and `/tmp/x` is in
    /// `/private/tmp`. The one way to ask it: a `hasPrefix(folder + "/")` by hand misses the links.
    public static func inside(_ path: String, _ folder: String) -> Bool {
        let (path, folder) = (realNearest(path), realNearest(folder))
        return path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    /// A path as it really is; one not there (yet) is its nearest folder that is, as it really is, and the rest as written.
    public static func realNearest(_ path: String) -> String {
        let standard = (URL(fileURLWithPath: path).path as NSString).standardizingPath
        if let resolved = Paths.real(standard) { return resolved }
        let up = (standard as NSString).deletingLastPathComponent
        return up == standard
            ? standard : (realNearest(up) as NSString).appendingPathComponent((standard as NSString).lastPathComponent)
    }

    /// A file of Resources/. Found by hand, not with Bundle.module, which stops the process when the bundle isn't where it
    /// looks (`kelp` run through a symlink).
    public static func resource(_ name: String, _ ext: String) -> String? {
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        let dirs = [
            Bundle.main.resourceURL, Bundle(for: BundleToken.self).resourceURL,
            exe?.appendingPathComponent("../Resources"), exe
        ]
        let bundles = dirs.lazy.compactMap { $0.flatMap { Bundle(url: $0.appendingPathComponent("Kelp_Core.bundle")) } }
        let found = bundles.compactMap { $0.url(forResource: name, withExtension: ext) }
        return found.first.flatMap { String(contentsIfAny: $0) }
    }
    private final class BundleToken {}
}
