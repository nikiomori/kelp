import Core
import Foundation

/// Kelp's skills for an agent that has no flag to load them for one session (Codex, Antigravity, Grok…). They are
/// copied into the folder the agent works in, as `.agents/skills/kelp-*/SKILL.md`, which is where those agents all read
/// a project's skills from, and kept out of git by the repository's own info/exclude. Nothing goes into the agent's own
/// config. They are the same skills a Claude Code chat in that folder would get (`chosenSkills`). A Kelp skill turned
/// off since is removed from the folder; someone else's skill named `kelp-…` stays.
extension SessionSetup {
    static let projectSkills = ".agents/skills"

    /// Writes the skills for a chat starting in `cwd`, and returns the hover card's line about the browser skill (nil
    /// without it).
    func writeProjectSkills(worktreeId: String?, cwd: String) -> String? {
        let (on, browser) = chosenSkills(worktreeId: worktreeId, cwd: cwd)
        let folder = URL(fileURLWithPath: cwd).appendingPathComponent(Self.projectSkills)
        Log.store.attempt("Kelp's skills in \(cwd)") {
            let kelps = WebApp.folders(in: Paths.agentSkills(in: root)).map(\.lastPathComponent)
            try Self.copy(on, into: folder, kelps: Set(kelps))
            if !on.isEmpty { try Artifacts.excludeFromGit(root: cwd, entry: "/\(Self.projectSkills)/kelp-*/") }
        }
        return browser?.line
    }

    /// Copies each plugin's skill folder to `<folder>/<name>/`, writing only where it differs, and removes Kelp's other
    /// skills there (`kelps` holds the names of all of Kelp's skills).
    static func copy(_ plugins: [URL], into folder: URL, kelps: Set<String>) throws {
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
        for old in try fm.contentsOfDirectory(atPath: folder.path) where kelps.contains(old) && !names.contains(old) {
            try fm.removeItem(at: folder.appendingPathComponent(old))
        }
    }
}
