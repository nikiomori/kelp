import AppKit
import Core
import EditorKit
import KelpKit

/// Snippets in VS Code's format, so existing ones can be copied over. The user's are in
/// `~/.kelp/snippets/<language>.json`, and a project's own are in `.kelp/snippets/`. They are read each time they're
/// asked for, so a file just edited counts at once.
enum Snippets {
    /// Reads a snippets file: `{"Name": {"prefix": "x" or […], "body": "…" or […], "description": "…"}}`, with
    /// comments allowed.
    static func read(_ text: String, path: String) throws -> [CodeEditor.Completion] {
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.json5Allowed])
        guard let all = json as? [String: Any] else { return [] }
        return all.keys.sorted().flatMap { name -> [CodeEditor.Completion] in
            guard let entry = all[name] as? [String: Any], let body = lines(entry["body"]) else { return [] }
            let insert = fill(body.joined(separator: "\n"), path: path)
            return (lines(entry["prefix"]) ?? []).map { prefix in
                CodeEditor.Completion(
                    label: prefix, detail: name, insert: insert, kind: "snippet",
                    documentation: entry["description"] as? String, snippet: true)
            }
        }
    }

    private static func lines(_ value: Any?) -> [String]? { (value as? String).map { [$0] } ?? value as? [String] }

    /// Fills in the variables that copied snippets use most. Longer names are replaced first, because one name can
    /// start with another.
    static func fill(_ body: String, path: String, now: Date = Date()) -> String {
        let name = (path as NSString).lastPathComponent,
            date = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let values: [(String, String)] = [
            ("TM_FILENAME_BASE", (name as NSString).deletingPathExtension), ("TM_FILENAME", name),
            ("TM_FILEPATH", path),
            ("TM_DIRECTORY", (path as NSString).deletingLastPathComponent), ("TM_SELECTED_TEXT", ""),
            ("CURRENT_YEAR", "\(date.year ?? 0)"),
            ("CURRENT_MONTH", String(format: "%02d", date.month ?? 0)),
            ("CURRENT_DATE", String(format: "%02d", date.day ?? 0))
        ]
        return values.reduce(body) { text, v in
            text.replacingOccurrences(of: "${\(v.0)}", with: v.1).replacingOccurrences(of: "$\(v.0)", with: v.1)
        }
    }

    /// Loads the project's snippets, then the user's. Having no file is the usual case, but a file that can't be read
    /// shows a banner.
    @MainActor static func load(app: AppModel, language: String, root: String, path: String) async -> [CodeEditor
        .Completion]
    {
        var found: [CodeEditor.Completion] = []
        for folder in [root + "/.kelp/snippets", Paths.root.appendingPathComponent("snippets").path] {
            let file = folder + "/" + language + ".json"
            guard let text = await app.quiet(FilesRead(path: file))?.text else { continue }
            do {
                found += try read(text, path: path)
            } catch {
                Banner.show(String(localized: "\(file) can't be read: \(error.localizedDescription)"), style: .error)
            }
        }
        return found
    }
}
