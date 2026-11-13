import Core
import Foundation

// addons.tidy: Tidy Up's run in Kelp's home, `tidy/<when>/`: the brief the agent follows, and the files as they were
// before (`before/` and each one's own path), for Compare with Before Tidy Up.

enum TidyRuns {
    static func folder(_ root: URL) -> URL { root.appendingPathComponent("tidy") }

    /// What a run keeps of an instruction file: a memory index's whole folder (the agent moves its memories too).
    static func kept(_ path: String) -> String {
        (path as NSString).lastPathComponent == "MEMORY.md" ? (path as NSString).deletingLastPathComponent : path
    }

    /// The copy of `path` from the newest run that has one.
    static func before(_ path: String, root: URL) -> String? {
        let runs: [String]
        do { runs = try FileManager.default.contentsOfDirectory(atPath: folder(root).path) } catch { return nil }
        let kept = kept(path)
        return runs.sorted(by: >).lazy.map { folder(root).appendingPathComponent($0).path + "/before" + kept }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// A run's name: when it started, sortable ("2026-11-13-053012").
    static func stamp(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd-HHmmss"
        return format.string(from: date)
    }

    /// The files as the agent is told them: Claude Code's memory index stands for its whole folder.
    static func described(_ paths: [String]) -> String {
        paths.map { path in
            guard (path as NSString).lastPathComponent == "MEMORY.md" else { return path }
            return "Claude Code's memory in \(kept(path))/ (MEMORY.md, its index, and the memory files beside it)"
        }.joined(separator: "; ")
    }
}

extension AddonsTidy: Handled {
    func handle(_ workspaces: Workspaces) throws -> String {
        let (_, repo) = try workspaces.configRepo(worktreeId)
        let files = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !files.isEmpty else { throw RPCError.invalidParams("no instruction file to tidy") }
        let run = TidyRuns.folder(workspaces.root).appendingPathComponent(TidyRuns.stamp(Date()))
        let manager = FileManager.default
        for file in files {
            let kept = TidyRuns.kept(file), copy = run.appendingPathComponent("before" + kept)
            try manager.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(atPath: kept, toPath: copy.path)
        }
        let brief = run.appendingPathComponent("brief.md")
        let text = Recipes.render(
            "tidyInstructions", config: workspaces.trustedConfig(repo),
            vars: ["instructionFiles": TidyRuns.described(files)])
        try text.write(to: brief, atomically: true, encoding: .utf8)
        return "Tidy up this project's instructions: \(TidyRuns.described(files)). Read \(brief.path) and follow it."
    }
}
