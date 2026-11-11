import Core
import Foundation

/// The person's own skill folders, changed at their word: one moved to the Trash, linked where the other agents read,
/// made new, or copied in from a folder. A skill sits once, in the folder the agents share (`.agents/skills`), with a
/// link in Claude Code's, which reads only its own: the layout `npx skills` makes.
extension AddonFiles {
    public struct Plugin: Sendable, Equatable {
        /// "sales@synced", "ponytail@ponytail": what the agent's own `plugin uninstall` takes.
        public var id: String, dir: URL
    }

    /// Claude Code's plugins by name: those it installed (with their folder) and claude.ai's, which sync into one.
    public func plugins() -> [String: Plugin] {
        var out: [String: Plugin] = [:]
        let synced = claude.appendingPathComponent("plugins/synced")
        for account in FileManager.default.items(in: synced) {
            for dir in FileManager.default.items(in: account) where dir.hasDirectoryPath {
                out[dir.lastPathComponent] = Plugin(id: dir.lastPathComponent + "@synced", dir: dir)
            }
        }
        let file = claude.appendingPathComponent("plugins/installed_plugins.json")
        let installed = Data(contentsIfAny: file).flatMap(JSONL.object)?["plugins"] as? [String: Any] ?? [:]
        for (id, installs) in installed {
            guard let name = id.split(separator: "@").first.map(String.init),
                let path = (installs as? [[String: Any]])?.first?["installPath"] as? String
            else { continue }
            out[name] = Plugin(id: id, dir: URL(fileURLWithPath: path))
        }
        return out
    }

    /// The two folders skills go in: the shared one and Claude Code's, the person's or the project's.
    func skillFolders(cwd: String, project: Bool) -> (shared: URL, claude: URL) {
        guard project else {
            return (home.appendingPathComponent(".agents/skills"), claude.appendingPathComponent("skills"))
        }
        let root = URL(fileURLWithPath: cwd)
        return (root.appendingPathComponent(".agents/skills"), root.appendingPathComponent(".claude/skills"))
    }

    /// Every place a skill of this name sits in, links and real folders alike.
    private func places(_ name: String, cwd: String) -> [Skill] { skills(cwd: cwd).filter { $0.name == name } }

    /// The skill's real folders go to the Trash and the links to them go away. Throws when there's no such skill.
    public func trashSkill(_ name: String, cwd: String) throws {
        let found = places(name, cwd: cwd)
        guard !found.isEmpty else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name]) }
        for place in found where place.real != place.path {
            try FileManager.default.removeItem(atPath: place.path)   // a link: only itself
        }
        for real in Set(found.filter { $0.real == $0.path }.map(\.path)) {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: real), resultingItemURL: nil)
        }
    }

    /// A link to the skill in each of its scope's two folders that lacks it, so every agent reads it.
    public func linkSkill(_ name: String, cwd: String) throws {
        let found = places(name, cwd: cwd)
        guard let home = found.first(where: { $0.real == $0.path }) ?? found.first else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
        }
        let folders = skillFolders(cwd: cwd, project: home.project)
        for folder in [folders.shared, folders.claude] {
            let link = folder.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: link.path) else { continue }
            try Paths.ensure(folder)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: home.real))
        }
    }

    /// A new skill to fill in: its folder with a SKILL.md, and the link. Returns the SKILL.md.
    public func newSkill(_ name: String, cwd: String, project: Bool) throws -> String {
        let folder = try place(name, cwd: cwd, project: project)
        try Paths.ensure(folder)
        let text = """
            ---
            name: \(name)
            description: Use when … (when an agent should reach for this: all it sees of the skill until then)
            ---

            # \(name)

            What to do, step by step.

            """
        let file = folder.appendingPathComponent("SKILL.md")
        try text.write(to: file, atomically: true, encoding: .utf8)
        try linkSkill(name, cwd: cwd)
        return file.path
    }

    /// Copies in the skills of `source`: itself when it holds a SKILL.md, else every folder up to three levels down
    /// that does (a repository's `skills/<name>`). Returns their SKILL.md files; throws when it holds none, or one of
    /// that name is there already.
    public func installSkills(from source: URL, cwd: String, project: Bool) throws -> [String] {
        let found = Self.skillFolders(in: source, depth: 3)
        guard !found.isEmpty else {
            throw CocoaError(
                .fileReadCorruptFile,
                userInfo: [NSLocalizedDescriptionKey: "No SKILL.md in \(source.lastPathComponent): not a skill"])
        }
        return try found.map { folder in
            let name = folder.lastPathComponent
            let target = try place(name, cwd: cwd, project: project)
            try Paths.ensure(target.deletingLastPathComponent())
            try FileManager.default.copyItem(at: folder, to: target)
            // A copied repository's history isn't the skill.
            FileManager.default.removeIfAny(target.appendingPathComponent(".git"))
            try linkSkill(name, cwd: cwd)
            return target.appendingPathComponent("SKILL.md").path
        }
    }

    /// Where a new skill of this name goes; throws for a name the agents wouldn't take, or one already there.
    private func place(_ name: String, cwd: String, project: Bool) throws -> URL {
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            throw CocoaError(
                .fileWriteInvalidFileName,
                userInfo: [NSLocalizedDescriptionKey: "A skill's name is letters, digits, - and _: “\(name)” isn't"])
        }
        let folders = skillFolders(cwd: cwd, project: project)
        for folder in [folders.shared, folders.claude]
        where FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            throw CocoaError(
                .fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "There's a skill named \(name) already"])
        }
        return folders.shared.appendingPathComponent(name)
    }

    static func skillFolders(in folder: URL, depth: Int) -> [URL] {
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("SKILL.md").path) { return [folder] }
        guard depth > 0 else { return [] }
        return FileManager.default.items(in: folder)
            .filter { $0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.path < $1.path }
            .flatMap { skillFolders(in: $0, depth: depth - 1) }
    }
}
