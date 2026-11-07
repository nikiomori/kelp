import Foundation

/// The IDE verbs of `kelp`: how agents drive the app (through the daemon's `ui.*` / `settings.*`).
public enum IDE {
    /// A path dropped into an agent's prompt: backslash escapes, which shells and agents (Claude Code, Codex) all read;
    /// Claude strips only one pair of quotes, so the POSIX `'…'\''…'` form leaks into the path (Ghostty does the same).
    public static func escapedPath(_ path: String) -> String {
        var out = ""
        for c in path {
            if "\\ ()[]{}<>\"'`!#$&;|*?\t".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// One shell word, single-quoted (`'…'\''…'`): commands Kelp writes itself. The shell expands nothing inside.
    public static func shellWord(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: open

    /// What `ui.open` gets for a CLI/agent target: http(s) and tab URIs as is, `path:12` → `file:///abs/path#L12`, other paths made absolute.
    public static func uri(for target: String, cwd: String) -> String {
        if target.hasPrefix("http://") || target.hasPrefix("https://") { return target }
        if let m = target.wholeMatch(of: /(.+):(\d+)/) {
            return URL(fileURLWithPath: absolute(String(m.1), cwd: cwd)).absoluteString + "#L\(m.2)"
        }
        let path = absolute(target, cwd: cwd)
        if target.wholeMatch(of: /[a-z][a-z0-9+.-]*:.*/) != nil, !FileManager.default.fileExists(atPath: path) {
            return target
        }   // session:, diff:, ext:…
        return path
    }

    /// Opens `target` in the editor area of the workspace that contains `cwd` (when there is one).
    /// `focus`: bring Kelp to the front and switch to that workspace (otherwise the tab waits there quietly).
    public static func open(_ target: String, split: String?, cwd: String, focus: Bool = false, client c: RPCClient)
        async throws -> Delivered
    {
        let w = try? await workspace(cwd: cwd, client: c)
        return try await c.call(
            UIOpen(uri: uri(for: target, cwd: cwd), split: split, focus: focus ? true : nil, worktreeId: w?.id))
    }

    /// The workspace a command run in `cwd` means (`workspace(cwd:among:own:)`), from the daemon's lists.
    public static func workspace(
        cwd: String, session: String? = ProcessInfo.processInfo.environment["KELP_SESSION"],
        client c: RPCClient
    ) async throws -> Worktree? {
        let all = try await c.call(WorktreeList())
        let own = session == nil ? nil : (try? await c.call(SessionList()))?.first { $0.id == session }?.worktreeId
        return workspace(cwd: cwd, among: all, own: own)
    }

    /// Workspaces of a project share its folder, so the folder alone can't tell them apart: the agent's own (`own`, its
    /// KELP_SESSION's workspace) wins when it holds `cwd`, else the first one that does.
    public static func workspace(cwd: String, among all: [Worktree], own: String?) -> Worktree? {
        let here = all.filter { inside(cwd, $0.path) }
        return here.first { $0.id == own } ?? here.first
    }

    static func absolute(_ path: String, cwd: String) -> String {
        URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).standardizedFileURL.path
    }

    public static func inside(_ dir: String, _ root: String) -> Bool {
        let (d, r) = (
            URL(fileURLWithPath: dir).resolvingSymlinksInPath().path,
            URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        )
        return d == r || d.hasPrefix(r + "/")
    }

    // MARK: extensions

    public static func isValidExtensionID(_ id: String) -> Bool { id.wholeMatch(of: /[a-z0-9][a-z0-9.-]*/) != nil }

    /// What the app shows (`ui.state`) when it runs, else the folders in `dir`.
    public static func extensions(client c: RPCClient, dir: URL) async throws -> JSONValue {
        if let shown = try await c.call(UIStateGet())["extensions"] { return shown }
        let disabled = try await disabledExtensions(client: c)
        let folders = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return .array(
            folders.sorted { $0.path < $1.path }.compactMap { f in
                guard let d = try? Data(contentsOf: f.appendingPathComponent("extension.json")) else { return nil }
                let id = f.lastPathComponent
                let name = (try? JSONDecoder().decode(JSONValue.self, from: d))?["name"] ?? .string(id)
                return .obj([
                    "id": .string(id), "name": name, "enabled": .bool(!disabled.contains(id)), "builtin": false,
                    "path": .string(f.path)
                ])
            })
    }

    /// Enabling/disabling is the `extensions.disabled` setting; the app applies it.
    public static func setExtension(_ id: String, enabled: Bool, client c: RPCClient) async throws {
        guard isValidExtensionID(id) else { throw invalidID(id) }
        let rest = try await disabledExtensions(client: c).filter { $0 != id }
        let list = enabled ? rest : rest + [id]
        _ = try await c.call(SettingsSet(key: "extensions.disabled", value: .array(list.map { .string($0) })))
    }

    static func disabledExtensions(client c: RPCClient) async throws -> [String] {
        (try await c.call(SettingsGet())["extensions.disabled"]?.array ?? []).compactMap(\.string)
    }

    static func invalidID(_ id: String) -> RPCError {
        .invalidParams("invalid extension id \"\(id)\": use lowercase letters, digits, dots and dashes")
    }

    /// `<dir>/<id>/` with a working starter (extension.json + README.md), and the authoring guide next to it. Returns the folder.
    @discardableResult
    public static func scaffoldExtension(id: String, name: String?, description: String?, in dir: URL) throws -> URL {
        guard isValidExtensionID(id) else { throw invalidID(id) }
        let folder = dir.appendingPathComponent(id)
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw RPCError.invalidParams("\(folder.path) already exists")
        }
        try Paths.ensure(folder)
        try writeGuide(in: dir)
        let name = name ?? id.replacingOccurrences(of: "-", with: " ").capitalized
        try starterManifest(id: id, name: name, description: description ?? "")
            .write(to: folder.appendingPathComponent("extension.json"), atomically: true, encoding: .utf8)
        try starterReadme(name: name, description: description ?? "").write(
            to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        return folder
    }

    /// The extension authoring guide (Resources/extensions.md; docs/extensions.md links to it).
    public static let extensionGuide = resource("extensions", "md") ?? ""

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
        return found.first.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
    private final class BundleToken {}

    /// EXTENSIONS.md, rewritten when missing or older than this build's guide.
    public static func writeGuide(in dir: URL) throws {
        let u = dir.appendingPathComponent("EXTENSIONS.md")
        guard !extensionGuide.isEmpty, (try? String(contentsOf: u, encoding: .utf8)) != extensionGuide else { return }
        try Paths.ensure(dir)
        try extensionGuide.write(to: u, atomically: true, encoding: .utf8)
    }

    static func jsonString(_ s: String) -> String {
        let e = JSONEncoder()
        e.outputFormatting = .withoutEscapingSlashes
        return (try? e.encode(s)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "\"\""
    }

    /// A list panel of the workspace's top-level files; the command prints JSON lines with nothing but find + stat.
    static func starterManifest(id: String, name: String, description: String) -> String {
        #"""
        {
          "id": \#(jsonString(id)),
          "name": \#(jsonString(name)),
          "version": "0.1.0",
          "description": \#(jsonString(description)),
          "icon": "puzzlepiece.extension",
          "contributes": {
            "panels": [
              {
                "id": "files",
                "title": \#(jsonString(name)),
                "icon": "puzzlepiece.extension",
                "list": {
                  "command": "find . -maxdepth 1 -type f -not -name '.*' -exec stat -f '{\"name\":\"%N\",\"size\":%z}' {} \\;",
                  "refresh": 10,
                  "title": "${name}",
                  "subtitle": "${size} bytes",
                  "icon": "doc",
                  "empty": "No files here",
                  "actions": [
                    { "title": "Open", "icon": "doc.text", "open": "${workspace.path}/${name}" }
                  ]
                }
              }
            ]
          }
        }

        """#
    }

    static func starterReadme(name: String, description: String) -> String {
        """
        # \(name)

        \(description.isEmpty ? "A Kelp extension." : description)

        This starter adds a "\(name)" panel to the right inspector: the files at the top of the workspace,
        refreshed every 10 seconds; double-click one to open it.

        Edit `extension.json` — Kelp reloads it when it changes (or run `kelp ext reload`).
        The format is described in `../EXTENSIONS.md`.

        """
    }
}
