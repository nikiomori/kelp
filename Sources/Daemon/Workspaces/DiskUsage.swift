import AgentData
import Core
import Foundation
import GitKit

/// What a project takes on this Mac (`repo.diskUsage`), and moving its parts to the Trash (`repo.diskTrash`): handed the
/// workspaces, whose worktrees it measures and removes.
struct DiskUsage: Sendable {
    typealias Item = RepoDiskUsage.Item
    let workspaces: Workspaces

    /// Folders a build or a package manager makes again: what's in them costs only time.
    static let buildNames: Set<String> = [
        ".build", "node_modules", "DerivedData", ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".angular",
        "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".gradle", ".dart_tool", "Pods"
    ]
    /// Parts smaller than this aren't listed (a stray .DS_Store); they still count in the files.
    static let smallest = 1 << 20
    static let derivedData = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Developer/Xcode/DerivedData")

    /// `target` is Cargo's or Maven's only beside its manifest; elsewhere it may be anything.
    static func isBuild(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path), name = url.lastPathComponent
        if buildNames.contains(name) { return true }
        let dir = url.deletingLastPathComponent().path
        return name == "target" && ["Cargo.toml", "pom.xml"].contains { exists(dir + "/" + $0) }
    }

    /// `root` is the project's folder as git prints it (symlinks resolved); `worktrees` its other worktrees with their
    /// sizes (`repo.worktreeSizes`).
    static func measure(
        root: String, worktrees: [RepoWorktreeSizes.Item], remotes: Remotes, chats: URL = ClaudeHistory.defaultRoot,
        derived: URL = derivedData
    ) throws -> [Item] {
        let inside = { (dir: String) in worktrees.filter { $0.path.hasPrefix(dir + "/") } }
        // The project's folder: what git ignores, less the worktrees inside it (measured as their own).
        // git lists a folder whose every entry it ignores along with those entries (`.kelp/` and `.kelp/artifacts/`):
        // the entries count, the folder doesn't, and nothing counts twice.
        let listed = try ProjectFiles.ignored(root, remotes: remotes).map(trimmed)
        let really = try Git.ignored(listed, cwd: root, remotes: remotes)
        let rels = outermost(
            listed.filter { rel in really.contains(rel) || !listed.contains { $0.hasPrefix(rel + "/") } })
        let ignored = rels.map { root + "/" + $0 }, sizes = try du(ignored), total = try du([root])[root] ?? 0
        var items: [Item] = [], outside = total - inside(root).reduce(0) { $0 + $1.bytes }
        for (rel, path) in zip(rels, ignored) where !worktrees.contains(where: { $0.path == path }) {
            let nested = inside(path), bytes = (sizes[path] ?? 0) - nested.reduce(0) { $0 + $1.bytes }
            outside -= bytes
            items.append(
                Item(
                    path: path, bytes: bytes, what: isBuild(path) ? .build : .ignored,
                    removable: nested.isEmpty && really.contains(rel)))
        }
        items.append(Item(path: root, bytes: max(0, outside), what: .files, removable: false))
        // Each other worktree: its builds, then the rest of it.
        for worktree in worktrees {
            let builds = outermost(try ProjectFiles.ignored(worktree.path, remotes: remotes).map(trimmed))
                .map { worktree.path + "/" + $0 }.filter(isBuild)
            let sizes = try du(builds)
            var rest = worktree.bytes
            for path in builds {
                rest -= sizes[path] ?? 0
                items.append(
                    Item(path: path, bytes: sizes[path] ?? 0, what: .build, removable: true, worktree: worktree.path))
            }
            items.append(Item(path: worktree.path, bytes: max(0, rest), what: .worktree, removable: worktree.removable))
        }
        let roots = [root] + worktrees.map(\.path)
        let xcode = builtFor(roots, in: derived), sizesX = try du(xcode)
        items += xcode.map { Item(path: $0, bytes: sizesX[$0] ?? 0, what: .build, removable: true) }
        let talks = roots.map { chats.appendingPathComponent(claudeName($0)).path }.filter(exists),
            sizesC = try du(talks)
        items += talks.map { Item(path: $0, bytes: sizesC[$0] ?? 0, what: .chats, removable: false) }
        return items.filter { $0.bytes >= smallest || $0.what == .files }.sorted { $0.bytes > $1.bytes }
    }

    /// The DerivedData folders Xcode keeps for a workspace or package in one of `roots`.
    static func builtFor(_ roots: [String], in derived: URL) -> [String] {
        let dirs = FileManager.default.enumerator(
            at: derived, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants])
        return (dirs?.allObjects as? [URL] ?? []).filter { dir in
            guard
                let workspace = NSDictionary(contentsOf: dir.appendingPathComponent("info.plist"))?["WorkspacePath"]
                    as? String
            else { return false }
            return roots.contains { Paths.inside(workspace, $0) }
        }.map(\.path)
    }

    /// The folder Claude Code keeps a folder's conversations in: its path with every other character than a letter or a
    /// digit as "-". Limit: the default config folder and CLAUDE_CONFIG_DIR's, not account profiles' own.
    static func claudeName(_ path: String) -> String {
        String(path.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
    }

    /// Blocks on disk as `du` counts them, for each path that's there; one program for many paths.
    static func du(_ paths: [String]) throws -> [String: Int] {
        var out: [String: Int] = [:]
        for chunk in stride(from: 0, to: paths.count, by: 256).map({ Array(paths[$0..<min($0 + 256, paths.count)]) }) {
            // 1: something in it couldn't be read; the rest is counted.
            let data = try Subprocess.output(["/usr/bin/du", "-sk"] + chunk, cwd: "/", ok: [0, 1])
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                guard let tab = line.firstIndex(of: "\t"), let kb = Int(line[..<tab]) else { continue }
                out[String(line[line.index(after: tab)...])] = kb * 1024
            }
        }
        return out
    }

    /// Without those inside another of them.
    static func outermost(_ rels: [String]) -> [String] {
        var kept: [String] = []
        for rel in rels.sorted() where !kept.contains(where: { rel.hasPrefix($0 + "/") }) { kept.append(rel) }
        return kept
    }

    /// The path as git prints it, every link resolved (`/private/tmp`, not `/tmp`).
    static func real(_ path: String) -> String { Paths.real(path) ?? path }
    static func trimmed(_ rel: String) -> String { rel.hasSuffix("/") ? String(rel.dropLast()) : rel }
    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
}

extension DiskUsage {
    func measure(_ repo: Repo) throws -> [Item] {
        guard workspaces.remotes.of(repo.path) == nil else { return [] }   // their disk is on the host
        return try Self.measure(
            root: Self.real(repo.path), worktrees: RepoWorktreeSizes(id: repo.id).handle(workspaces),
            remotes: workspaces.remotes)
    }

    /// Worktrees as `removeWorktrees` takes them; anything else to the Trash only if it's in the project's folder or a
    /// worktree, git ignores it and tracks nothing in it, and no worktree is inside; or it's DerivedData Xcode keeps for
    /// the project.
    func trash(_ paths: [String], of repo: Repo, derived: URL = derivedData) throws -> RepoRemoveWorktrees.Result {
        let remotes = workspaces.remotes, root = Self.real(repo.path)
        let linked = try Git.linkedWorktrees(repo.path, remotes: remotes).map(\.path)
        let roots = [root] + linked, xcode = Set(Self.builtFor(roots, in: derived))
        var out = try workspaces.removeWorktrees(paths.filter(linked.contains), of: repo)
        for path in paths where !linked.contains(path) {
            // As it really is: `..` or a link can't take it out of the project.
            let real = Self.real(path)
            do {
                if let why = xcode.contains(real) ? nil : try refusal(real, roots: roots) {
                    out.kept[path] = why
                    continue
                }
                try Trash.move(URL(fileURLWithPath: real))
                out.removed.append(path)
            } catch { out.kept[path] = (error as? GitError)?.message ?? error.localizedDescription }
        }
        return out
    }

    /// Why `path` isn't Kelp's to move to the Trash, or nil when it is.
    private func refusal(_ path: String, roots: [String]) throws -> String? {
        guard let base = roots.filter({ path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }),
            Self.exists(path)
        else { return "Not part of the project." }
        let rel = String(path.dropFirst(base.count + 1)), remotes = workspaces.remotes
        guard try Git.ignored([rel], cwd: base, remotes: remotes).contains(rel),
            try Git.run(["ls-files", "-z", "--", rel], cwd: base, remotes: remotes).isEmpty
        else { return "Git tracks it." }
        return roots.contains { $0.hasPrefix(path + "/") } ? "A worktree is inside it." : nil
    }
}
