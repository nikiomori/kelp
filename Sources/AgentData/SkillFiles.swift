import Core
import Foundation

/// Changes the person's own skill folders when the person asks: moves a skill to the Trash, links it where the other
/// agents read, makes a new one, or copies one in from a folder. Each skill sits once, in the folder the agents share
/// (`.agents/skills`), with a link in Claude Code's folder, because Claude Code reads only its own. This is the layout
/// that `npx skills` makes.
extension AddonFiles {
    public struct Plugin: Sendable, Equatable {
        /// The plugin's id, such as "sales@synced" or "ponytail@ponytail", which the agent's `plugin uninstall` takes.
        public var id: String, dir: URL
    }

    /// Returns Claude Code's plugins by name: those it installed, with their folders, and claude.ai's plugins, which
    /// sync into a folder of their own.
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

    /// The two folders skills go in, the shared one and Claude Code's, either the person's or the project's.
    func skillFolders(cwd: String, project: Bool) -> (shared: URL, claude: URL) {
        guard project else {
            return (home.appendingPathComponent(".agents/skills"), claude.appendingPathComponent("skills"))
        }
        let root = URL(fileURLWithPath: cwd)
        return (root.appendingPathComponent(".agents/skills"), root.appendingPathComponent(".claude/skills"))
    }

    /// Returns every place that holds a skill of this name, links and real folders alike.
    private func places(_ name: String, cwd: String) -> [Skill] { skills(cwd: cwd).filter { $0.name == name } }

    /// Moves the skill's real folders to the Trash and removes the links to them. Throws when there's no such skill.
    public func trashSkill(_ name: String, cwd: String) throws {
        let found = places(name, cwd: cwd)
        guard !found.isEmpty else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name]) }
        // Only a path that is itself a link counts as a link. A real folder reached through a linked parent
        // (~/.claude from dotfiles, /tmp for /private/tmp) also resolves elsewhere, and removing it would delete the
        // skill for good.
        let links = Set(
            found.map(\.path).filter { (try? FileManager.default.destinationOfSymbolicLink(atPath: $0)) != nil })
        for link in links { try FileManager.default.removeItem(atPath: link) }   // removes the link, not its target
        for real in Set(found.map(\.path)).subtracting(links) { try Trash.move(URL(fileURLWithPath: real)) }
    }

    /// Adds a link to the skill in each of its scope's two folders that lacks one, so that every agent reads it.
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

    /// Makes a new skill to fill in: its folder with a SKILL.md, and the link. Returns the SKILL.md's path.
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

    /// Copies in the skills in `source`: the folder itself when it holds a SKILL.md, or else every folder up to three
    /// levels down that does (a repository's `skills/<name>`). Returns the copied SKILL.md files. Throws when `source`
    /// holds no skill, or when a skill with the same name is already there.
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

    /// Returns where a new skill of this name goes. Throws for a name the agents wouldn't accept, or for a skill that
    /// is already there.
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
