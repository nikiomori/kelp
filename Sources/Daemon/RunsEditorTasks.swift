import Core
import Foundation

/// The tasks an editor keeps in the project, VS Code's .vscode/tasks.json and Zed's .zed/tasks.json, in the Run menu
/// beside package.json's scripts. Only what runs as a plain command. VS Code's npm tasks are package.json's own, listed
/// already; its other task types (gulp, typescript…) need VS Code. A task naming the open file or asking for input
/// (`${file}`, `${input:…}`, `$ZED_FILE`) has nothing to fill those in here and is left out.
extension Runnables {
    static func editorTasks(_ found: Found, _ base: String) -> [RunOption] {
        let vs = found.text(base, ".vscode/tasks.json").flatMap(JSONC.object)?["tasks"] as? [[String: Any]] ?? []
        let zed = found.text(base, ".zed/tasks.json").flatMap(JSONC.value) as? [[String: Any]] ?? []
        return vs.compactMap { vscode(found, base, $0) } + zed.compactMap { zedTask(found, base, $0) }
    }

    static func vscode(_ found: Found, _ base: String, _ task: [String: Any]) -> RunOption? {
        let spec = task.merging(task["osx"] as? [String: Any] ?? [:]) { $1 }   // its macOS variant
        guard [nil, "shell", "process"].contains(spec["type"] as? String), let program = spec["command"] as? String
        else {
            return nil
        }
        let args = (spec["args"] as? [Any] ?? []).compactMap { $0 as? String }.map(IDE.shellWord)
        let folder = ["${workspaceFolder}", "${workspaceRoot}"]
        guard var command = filled(([program] + args).joined(separator: " "), folder) else { return nil }
        if let cwd = (spec["options"] as? [String: Any])?["cwd"] as? String {
            guard let dir = filled(cwd, folder) else { return nil }
            if dir != "." { command = "cd \(IDE.shellWord(dir)) && \(command)" }
        }
        let name = spec["label"] as? String ?? program
        let group = spec["group"] as? String ?? (spec["group"] as? [String: Any])?["kind"] as? String
        return opt(
            found, base, ".vscode/tasks.json", name, command, kind: ["build", "test"].contains(group) ? group : nil)
    }

    static func zedTask(_ found: Found, _ base: String, _ task: [String: Any]) -> RunOption? {
        guard let program = task["command"] as? String else { return nil }
        let args = (task["args"] as? [Any] ?? []).compactMap { $0 as? String }.map(IDE.shellWord)
        let env = (task["env"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(IDE.shellWord($0.value))" }
        let root = ["$ZED_WORKTREE_ROOT", "${ZED_WORKTREE_ROOT}"]
        guard var command = filled((env + [program] + args).joined(separator: " "), root), !command.contains("ZED_")
        else { return nil }
        if let cwd = task["cwd"] as? String {
            guard let dir = filled(cwd, root), !dir.contains("ZED_") else { return nil }
            if dir != "." { command = "cd \(IDE.shellWord(dir)) && \(command)" }
        }
        return opt(found, base, ".zed/tasks.json", task["label"] as? String ?? program, command)
    }

    /// The project's folder written as the editor names it, here the folder the command runs in; nil if a variable is
    /// left that only the editor can fill.
    static func filled(_ text: String, _ folder: [String]) -> String? {
        let out = folder.reduce(text) { $0.replacingOccurrences(of: $1, with: ".") }
        return out.contains("${") ? nil : out
    }
}
