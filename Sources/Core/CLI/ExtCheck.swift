import Foundation

/// `kelp ext check <folder>`: what's wrong with an extension, each with where it is ("contributes.panels[0]: …"), before
/// Kelp loads it. The window keeps the last manifest that worked while one with a mistake is fixed.
public enum ExtCheck {
    /// Empty: nothing found wrong.
    public static func problems(in folder: URL) -> [String] {
        let file = folder.appendingPathComponent("extension.json")
        guard let data = FileManager.default.contents(atPath: file.path) else {
            return ["No extension.json in \(folder.path)."]
        }
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data) } catch {
            return [
                "extension.json isn't valid JSON: \((error as NSError).userInfo[NSDebugDescriptionErrorKey] ?? error.localizedDescription)"
            ]
        }
        guard let manifest = root as? [String: Any] else { return ["extension.json must be an object."] }
        var out: [String] = []
        for key in ["id", "name"] where (manifest[key] as? String ?? "").isEmpty {
            out.append("“\(key)” is missing: a non-empty string.")
        }
        let known: Set = ["id", "name", "version", "description", "icon", "requires", "contributes"]
        out += manifest.keys.filter { !known.contains($0) }.sorted().map { "Unknown key “\($0)” (a typo?)." }
        guard let contributes = manifest["contributes"] as? [String: Any] else { return out }
        for (kind, views) in [("panels", contributes["panels"]), ("editors", contributes["editors"])] {
            for (index, entry) in list(views).enumerated() {
                out += view(entry, at: "contributes.\(kind)[\(index)]", folder: folder)
            }
        }
        for (index, item) in list(contributes["commands"]).enumerated() {
            out += action(item, at: "contributes.commands[\(index)]")
        }
        for (index, setting) in list(contributes["settings"]).enumerated()
        where (setting["key"] as? String ?? "").isEmpty {
            out.append("contributes.settings[\(index)]: “key” is missing.")
        }
        for (index, theme) in list(contributes["iconThemes"]).enumerated() {
            if let file = theme["path"] as? String,
                !FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path)
            {
                out.append("contributes.iconThemes[\(index)]: no file “\(file)” in the folder.")
            }
        }
        return out
    }

    private static func list(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }

    private static func view(_ entry: [String: Any], at path: String, folder: URL) -> [String] {
        var out: [String] = []
        for key in ["id", "title"] where (entry[key] as? String ?? "").isEmpty {
            out.append("\(path): “\(key)” is missing.")
        }
        let list = entry["list"] as? [String: Any], web = entry["web"] as? String
        if (list == nil) == (web == nil) { out.append("\(path): needs exactly one of “list” or “web”.") }
        if let list, (list["command"] as? String ?? "").isEmpty { out.append("\(path).list: “command” is missing.") }
        for (index, item) in (list?["actions"] as? [[String: Any]] ?? []).enumerated() {
            out += action(item, at: "\(path).list.actions[\(index)]")
        }
        for (index, item) in (list?["toolbar"] as? [[String: Any]] ?? []).enumerated() {
            out += action(item, at: "\(path).list.toolbar[\(index)]")
        }
        if let web, !FileManager.default.fileExists(atPath: folder.appendingPathComponent(web).path) {
            out.append("\(path): no file “\(web)” in the folder.")
        }
        return out
    }

    private static func action(_ item: [String: Any], at path: String) -> [String] {
        var out: [String] = []
        if (item["title"] as? String ?? "").isEmpty { out.append("\(path): “title” is missing.") }
        let does = ["terminal", "run", "open", "agent"].filter { item[$0] is String }
        let has = does.isEmpty ? "none" : does.joined(separator: ", ")
        if does.count != 1 { out.append("\(path): needs exactly one of terminal, run, open, agent (has \(has)).") }
        return out
    }
}
