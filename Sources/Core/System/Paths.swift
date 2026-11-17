import Foundation

public enum Paths {
    /// Kelp's home folder, read once. Nothing sets KELP_HOME after launch (tests set it as their bundle loads). This is
    /// read for every project name drawn, and reading the bundle's Info.plist each time held up a workspace switch by
    /// ~50 ms.
    public static let root: URL = {
        // KELP_HOME picks another home (tests, snapshots). A build with a home of its own ignores it when it names
        // Kelp's own home, because a build started from a Kelp terminal inherits it (`open` passes the shell's on) and
        // would restart that kelpd, ending its agents.
        if let home = getenv("KELP_HOME").map({ URL(fileURLWithPath: String(cString: $0)) }),
            own == nil || home.standardizedFileURL.path != stable.path
        {
            return home
        }
        return own ?? stable
    }()
    /// Kelp's home, for a build that runs on a home of its own. The build's home starts as a copy of it (`HomeSeed`).
    public static var seed: URL? { own?.path == root.path ? stable : nil }
    private static var stable: URL { home.appendingPathComponent(".kelp") }
    /// The home of Kelp Beta and Kelp Dev, which name a home of their own (KelpHome, scripts/bundle.sh). Any debug
    /// build has one too.
    private static let own: URL? = {
        #if DEBUG
            home.appendingPathComponent(".kelp-dev")
        #else
            (Bundle.main.object(forInfoDictionaryKey: "KelpHome") as? String).map { home.appendingPathComponent($0) }
        #endif
    }()
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    public static var socket: URL { root.appendingPathComponent("kelp.sock") }
    public static var agents: URL { agents(in: root) }
    public static var extensions: URL { extensions(in: root) }
    /// The Claude Code plugins with Kelp's skills (one per skill that is turned on), loaded per session with
    /// --plugin-dir.
    public static var agentSkills: URL { agentSkills(in: root) }
    /// The same folders inside a given home (the daemon's, or a test's) rather than this process's own home.
    public static func agents(in root: URL) -> URL { root.appendingPathComponent("agents") }
    public static func extensions(in root: URL) -> URL { root.appendingPathComponent("extensions") }
    public static func agentSkills(in root: URL) -> URL { root.appendingPathComponent("agent-skills") }
    /// A folder for agents and terminals outside any project (Window › Scratch). It isn't listed with the projects.
    public static var scratch: URL { root.appendingPathComponent("scratch") }
    /// The file that says why kelpd last failed to start. kelpd writes it, it is removed once a kelpd starts, and the
    /// app's banner shows it.
    public static func daemonError(in root: URL) -> URL { root.appendingPathComponent("kelpd.err") }

    public static func ensure(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Returns `path` with its symlinks resolved, keeping "/private" (/tmp becomes /private/tmp, which
    /// resolvingSymlinksInPath strips). Nil when the path isn't there.
    public static func real(_ path: String) -> String? {
        realpath(path, nil).map { resolved in
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    /// Whether `path` is `folder` or inside it, comparing both as they really are: `..` and links are followed, and a
    /// relative path is taken from the current folder. So `/a/bc` isn't in `/a/b`, a link out of the folder isn't in
    /// it, and `/tmp/x` is in `/private/tmp`. Use this and not a hand-written `hasPrefix(folder + "/")`, which misses
    /// the links.
    public static func inside(_ path: String, _ folder: String) -> Bool {
        let (path, folder) = (realNearest(path), realNearest(folder))
        return path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    /// Returns `path` relative to `root` as written (`src/a.swift`), or nil when it isn't under `root`. It compares the
    /// paths as written, for showing a path. To ask whether a path is really in a folder (links, `..`), use `inside`.
    public static func relative(_ path: String, to root: String) -> String? {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil
    }

    /// Returns the real path. For a path that doesn't exist (yet), it resolves the nearest folder that does and keeps
    /// the rest as written.
    public static func realNearest(_ path: String) -> String {
        let standard = (URL(fileURLWithPath: path).path as NSString).standardizingPath
        if let resolved = Paths.real(standard) { return resolved }
        let up = (standard as NSString).deletingLastPathComponent
        return up == standard
            ? standard : (realNearest(up) as NSString).appendingPathComponent((standard as NSString).lastPathComponent)
    }

    /// Returns a file in Resources/. It is found by hand, not with Bundle.module, which stops the process when the
    /// bundle isn't where it looks (as for `kelp` run through a symlink).
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
