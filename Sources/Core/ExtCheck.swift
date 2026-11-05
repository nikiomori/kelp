import Foundation

/// `kelp ext check <folder>`: what's wrong with an extension, each with where it is ("contributes.panels[0]: …"), before
/// Kelp loads it. The window keeps the last manifest that worked while one with a mistake is fixed.
public enum ExtCheck {
    /// Empty: nothing found wrong.
    public static func problems(in folder: URL) -> [String] {
        let file = folder.appendingPathComponent("extension.json")
        guard let data = FileManager.default.contents(atPath: file.path) else { return ["No extension.json in \(folder.path)."] }
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data) } catch {
            return ["extension.json isn't valid JSON: \((error as NSError).userInfo[NSDebugDescriptionErrorKey] ?? error.localizedDescription)"]
        }
        guard let m = root as? [String: Any] else { return ["extension.json must be an object."] }
        var out: [String] = []
        for key in ["id", "name"] where (m[key] as? String ?? "").isEmpty { out.append("“\(key)” is missing: a non-empty string.") }
        let known: Set = ["id", "name", "version", "description", "icon", "requires", "contributes"]
        out += m.keys.filter { !known.contains($0) }.sorted().map { "Unknown key “\($0)” (a typo?)." }
        guard let c = m["contributes"] as? [String: Any] else { return out }
        for (kind, views) in [("panels", c["panels"]), ("editors", c["editors"])] {
            for (i, v) in list(views).enumerated() { out += view(v, at: "contributes.\(kind)[\(i)]", folder: folder) }
        }
        for (i, a) in list(c["commands"]).enumerated() { out += action(a, at: "contributes.commands[\(i)]") }
        for (i, s) in list(c["settings"]).enumerated() where (s["key"] as? String ?? "").isEmpty {
            out.append("contributes.settings[\(i)]: “key” is missing.")
        }
        for (i, t) in list(c["iconThemes"]).enumerated() {
            if let p = t["path"] as? String, !FileManager.default.fileExists(atPath: folder.appendingPathComponent(p).path) {
                out.append("contributes.iconThemes[\(i)]: no file “\(p)” in the folder.")
            }
        }
        return out
    }

    private static func list(_ v: Any?) -> [[String: Any]] { v as? [[String: Any]] ?? [] }

    private static func view(_ v: [String: Any], at path: String, folder: URL) -> [String] {
        var out: [String] = []
        for key in ["id", "title"] where (v[key] as? String ?? "").isEmpty { out.append("\(path): “\(key)” is missing.") }
        let list = v["list"] as? [String: Any], web = v["web"] as? String
        if (list == nil) == (web == nil) { out.append("\(path): needs exactly one of “list” or “web”.") }
        if let list, (list["command"] as? String ?? "").isEmpty { out.append("\(path).list: “command” is missing.") }
        for (i, a) in (list?["actions"] as? [[String: Any]] ?? []).enumerated() { out += action(a, at: "\(path).list.actions[\(i)]") }
        for (i, a) in (list?["toolbar"] as? [[String: Any]] ?? []).enumerated() { out += action(a, at: "\(path).list.toolbar[\(i)]") }
        if let web, !FileManager.default.fileExists(atPath: folder.appendingPathComponent(web).path) {
            out.append("\(path): no file “\(web)” in the folder.")
        }
        return out
    }

    private static func action(_ a: [String: Any], at path: String) -> [String] {
        var out: [String] = []
        if (a["title"] as? String ?? "").isEmpty { out.append("\(path): “title” is missing.") }
        let does = ["terminal", "run", "open", "agent"].filter { a[$0] is String }
        let has = does.isEmpty ? "none" : does.joined(separator: ", ")
        if does.count != 1 { out.append("\(path): needs exactly one of terminal, run, open, agent (has \(has)).") }
        return out
    }
}
