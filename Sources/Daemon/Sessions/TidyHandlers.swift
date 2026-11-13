import AgentData
import Core
import Foundation
import GitKit

// addons.tidy*: Tidy Up's runs in Kelp's home, `tidy/<when>/`: the brief the agent follows, the files as they were
// (`before/` and each one's own path), `run.json` (whose and which), `after/` once undone, `done` once ended.

enum TidyRuns {
    /// What a run records: the workspace it was for and the paths it kept (a memory index: its folder).
    struct Info: Codable {
        var worktreeId: String
        var kept: [String]
    }

    /// An open run is reviewed within this long; after it, its changes count as kept.
    static let open: TimeInterval = 24 * 3600

    static func folder(_ root: URL) -> URL { root.appendingPathComponent("tidy") }

    /// What a run keeps of an instruction file: a memory index's whole folder (the agent moves its memories too).
    static func kept(_ path: String) -> String {
        (path as NSString).lastPathComponent == "MEMORY.md" ? (path as NSString).deletingLastPathComponent : path
    }

    /// The copy of `path` from the newest run that has one.
    static func before(_ path: String, root: URL) -> String? {
        let kept = kept(path)
        return runs(root).lazy.map { $0.path + "/before" + kept }.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// The runs, newest first.
    static func runs(_ root: URL) -> [URL] {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: folder(root).path) } catch { return [] }
        return names.sorted(by: >).map { folder(root).appendingPathComponent($0) }
    }

    /// The workspace's newest run that's neither ended nor older than a day.
    static func open(_ worktreeId: String, root: URL, now: Date = Date()) -> (run: URL, info: Info)? {
        let manager = FileManager.default
        for run in runs(root) {
            guard let data = manager.contents(atPath: run.appendingPathComponent("run.json").path) else { continue }
            let info: Info, started: Date
            do {
                info = try JSONDecoder().decode(Info.self, from: data)
                started = try manager.attributesOfItem(atPath: run.path)[.creationDate] as? Date ?? now
            } catch { continue }   // a run from before run.json, or half written: not one to review
            guard info.worktreeId == worktreeId else { continue }
            let ended = manager.fileExists(atPath: run.appendingPathComponent("done").path)
            return ended || now.timeIntervalSince(started) > open ? nil : (run, info)
        }
        return nil
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

    /// What every chat reads of what a run kept, in tokens: a memory folder's index up to where Claude Code stops, any
    /// other file whole. `base` is where the kept paths sit (the run's copies, or "" for the files now).
    static func tokens(_ info: Info, base: String) -> Int {
        info.kept.reduce(0) { sum, kept in
            let index = base + kept + "/MEMORY.md"
            let memory = FileManager.default.fileExists(atPath: index)
            guard let data = FileManager.default.contents(atPath: memory ? index : base + kept) else { return sum }
            let read = memory ? data.prefix(InstructionChecks.memoryBytes) : data[...]
            return sum + ClaudeLoaded.tokens(String(decoding: read, as: UTF8.self).count)
        }
    }

    /// The run's copies against the files now, as the diff tab reads them: a memory folder's files as
    /// "memory/<name>", any other file by its name. Moves (into archive/) are renames, not whole files.
    static func diff(_ run: URL, _ info: Info, remotes: Remotes) throws -> [FileDiff] {
        try info.kept.flatMap { kept -> [FileDiff] in
            let before = run.path + "/before" + kept
            let output = try Git.run(
                ["diff", "--no-index", "-M", "--no-color", "--", before, kept], cwd: run.path, ok: [0, 1],
                remotes: remotes)
            let label = (kept as NSString).lastPathComponent
            let prefixes = [String(before.dropFirst()), String(kept.dropFirst())]
            return Git.parseDiff(output).map { file in
                var file = file
                for prefix in prefixes where file.path.hasPrefix(prefix) {
                    let rest = file.path.dropFirst(prefix.count)
                    file.path = rest.isEmpty ? label : label + rest
                }
                return file
            }
        }
    }

    /// Puts back every kept path from the run's copies; what was there goes to `after/`, so nothing is lost.
    static func undo(_ run: URL, _ info: Info) throws {
        let manager = FileManager.default
        for kept in info.kept {
            let copy = run.path + "/before" + kept, after = run.path + "/after" + kept
            guard manager.fileExists(atPath: copy) else { continue }
            try manager.createDirectory(
                atPath: (after as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if manager.fileExists(atPath: kept) { try manager.moveItem(atPath: kept, toPath: after) }
            try manager.copyItem(atPath: copy, toPath: kept)
        }
    }
}

extension AddonsTidy: Handled {
    func handle(_ workspaces: Workspaces) throws -> String {
        let (_, repo) = try workspaces.configRepo(worktreeId)
        let files = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !files.isEmpty else { throw RPCError.invalidParams("no instruction file to tidy") }
        let run = TidyRuns.folder(workspaces.root).appendingPathComponent(TidyRuns.stamp(Date()))
        let manager = FileManager.default
        let kept = files.map(TidyRuns.kept)
        for path in kept {
            let copy = run.appendingPathComponent("before" + path)
            try manager.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(atPath: path, toPath: copy.path)
        }
        let info = TidyRuns.Info(worktreeId: worktreeId, kept: kept)
        try JSONEncoder().encode(info).write(to: run.appendingPathComponent("run.json"))
        let brief = run.appendingPathComponent("brief.md")
        let text = Recipes.render(
            "tidyInstructions", config: workspaces.trustedConfig(repo),
            vars: ["instructionFiles": TidyRuns.described(files), "before": run.appendingPathComponent("before").path])
        try text.write(to: brief, atomically: true, encoding: .utf8)
        return "Tidy up this project's instructions: \(TidyRuns.described(files)). Read \(brief.path) and follow it."
    }
}

extension AddonsTidyEnd: Handled {
    func handle(_ workspaces: Workspaces) throws -> Done {
        guard let (run, info) = TidyRuns.open(worktreeId, root: workspaces.root) else {
            throw RPCError.invalidParams("no Tidy Up to end in this workspace")
        }
        // The one write Kelp makes to an agent's own files: its own copies back, on the person's Undo.
        if undo { try TidyRuns.undo(run, info) }
        try Data().write(to: run.appendingPathComponent("done"))
        return Done()
    }
}
