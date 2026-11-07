import Foundation

/// Markdown note templates (`<repo>/.kelp/templates`, `~/.kelp/templates`) with `{{placeholder}}` expansion.
public enum Templates {
    /// Built-ins `date` (yyyy-MM-dd), `time` (HH:mm), `datetime`; `vars` (branch, title, repo, …) override them.
    /// Unknown placeholders are left untouched.
    public static func expand(_ text: String, vars: [String: String], now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        func fmt(_ p: String) -> String {
            f.dateFormat = p
            return f.string(from: now)
        }
        let all = ["date": fmt("yyyy-MM-dd"), "time": fmt("HH:mm"), "datetime": fmt("yyyy-MM-dd HH:mm")].merging(vars) {
            $1
        }
        return text.replacing(/\{\{\s*([\w.\-]+)\s*\}\}/) { m in all[String(m.1)] ?? String(m.0) }
    }

    /// `*.md` files in `dir`, sorted by name; empty if the directory is missing.
    public static func list(in dir: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
