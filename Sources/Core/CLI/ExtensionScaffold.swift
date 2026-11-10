import Foundation

/// `kelp ext list|enable|disable|new`: the extensions as the app shows them, the setting that turns one off, a starter.
extension ExtensionFiles {
    /// What the app shows (`ui.state`) when it runs, else the folders in `dir`.
    public static func extensions(client: RPCClient, dir: URL) async throws -> JSONValue {
        if let shown = try await client.call(UIStateGet())["extensions"] { return shown }
        let disabled = try await disabledExtensions(client: client)
        let folders = FileManager.default.items(in: dir)
        return .array(
            folders.sorted { $0.path < $1.path }.compactMap { folder in
                guard let data = Data(contentsIfAny: folder.appendingPathComponent("extension.json")) else {
                    return nil
                }
                let id = folder.lastPathComponent
                let name = (try? JSONDecoder().decode(JSONValue.self, from: data))?["name"] ?? .string(id)
                return .obj([
                    "id": .string(id), "name": name, "enabled": .bool(!disabled.contains(id)), "builtin": false,
                    "path": .string(folder.path)
                ])
            })
    }

    /// Enabling/disabling is the `extensions.disabled` setting; the app applies it.
    public static func setExtension(_ id: String, enabled: Bool, client: RPCClient) async throws {
        guard isValidExtensionID(id) else { throw invalidID(id) }
        let rest = try await disabledExtensions(client: client).filter { $0 != id }
        let list = enabled ? rest : rest + [id]
        _ = try await client.call(
            SettingsSet(key: SettingKeys.disabledExtensions.key, value: .array(list.map(JSONValue.string))))
    }

    static func disabledExtensions(client: RPCClient) async throws -> [String] {
        try await SettingKeys.disabledExtensions.read(in: client.call(SettingsGet())) ?? []
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

    static func jsonString(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(text)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "\"\""
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
