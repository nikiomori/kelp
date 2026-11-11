import Core
import Foundation

/// Kelp's skills for an agent with no flag that loads them for one session (Codex, Antigravity, Grok…): copied into the
/// folder it works in, `.agents/skills/kelp-*/SKILL.md`, the place those agents all read a project's skills from, and
/// kept out of git by the repository's own info/exclude. Nothing goes into the agent's own config. The same skills a
/// Claude Code chat there would get (`chosenSkills`); one turned off since goes from the folder.
extension SessionSetup {
    static let projectSkills = ".agents/skills"

    /// Writes them for a chat starting in `cwd`; the hover card's line about the browser's (nil without it).
    func writeProjectSkills(worktreeId: String?, cwd: String) -> String? {
        let (on, browser) = chosenSkills(worktreeId: worktreeId, cwd: cwd)
        let folder = URL(fileURLWithPath: cwd).appendingPathComponent(Self.projectSkills)
        Log.store.attempt("Kelp's skills in \(cwd)") {
            try Self.copy(on, into: folder)
            if !on.isEmpty { try Artifacts.excludeFromGit(root: cwd, entry: "/\(Self.projectSkills)/kelp-*/") }
        }
        return browser?.line
    }

    /// Each plugin's skill folder as `<folder>/<name>/`, written only where it differs; Kelp's others there go.
    static func copy(_ plugins: [URL], into folder: URL) throws {
        let fm = FileManager.default
        let names = Set(plugins.map(\.lastPathComponent))
        for plugin in plugins {
            let name = plugin.lastPathComponent, from = plugin.appendingPathComponent("skills/\(name)")
            let files = fm.enumerator(atPath: from.path)?.allObjects as? [String] ?? []
            for file in files where Artifacts.fileStat(from.appendingPathComponent(file).path) != nil {
                let source = from.appendingPathComponent(file),
                    target = folder.appendingPathComponent("\(name)/\(file)")
                let bytes = try Data(contentsOf: source)
                guard fm.contents(atPath: target.path) != bytes else { continue }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: target, options: .atomic)
            }
        }
        guard fm.fileExists(atPath: folder.path) else { return }
        for old in try fm.contentsOfDirectory(atPath: folder.path) where old.hasPrefix("kelp-") && !names.contains(old)
        {
            try fm.removeItem(at: folder.appendingPathComponent(old))
        }
    }
}
