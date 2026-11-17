import AgentData
import Core
import Foundation
import GitKit

/// Measures how much disk a project takes (`repo.diskUsage`) and moves its parts aside (`repo.diskTrash`). It works on
/// this Mac, or on the host of a remote project, where git and `du` run over the project's connection
/// (`DiskUsage+Host`). It is given the workspaces because it measures and removes their worktrees.
struct DiskUsage: Sendable {
    typealias Item = RepoDiskUsage.Item
    let workspaces: Workspaces

    /// Folders that a build or a package manager makes again, so removing what's in them costs only time.
    static let buildNames: Set<String> = [
        ".build", "node_modules", "DerivedData", ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".angular",
        "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".gradle", ".dart_tool", "Pods"
    ]
    /// Parts smaller than this, such as a stray .DS_Store, aren't listed. Their bytes still count in the files.
    static let smallest = 1 << 20
    static let derivedData = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Developer/Xcode/DerivedData")

    /// Returns whether the path is a build folder. A `target` folder counts as a Cargo or Maven build only when it sits
    /// beside a Cargo.toml or pom.xml, because elsewhere it may hold anything.
    /// Limit: on a host, where the manifest isn't looked for, `target` isn't taken for a build.
    static func isBuild(_ path: String, here: Bool = true) -> Bool {
        let url = URL(fileURLWithPath: path), name = url.lastPathComponent
        if buildNames.contains(name) { return true }
        let dir = url.deletingLastPathComponent().path
        return here && name == "target" && ["Cargo.toml", "pom.xml"].contains { exists(dir + "/" + $0) }
    }

    /// The measurements of one project, taken on this Mac or on its host.
    struct Gathered {
        var root = "", total = 0, here = true
        var worktrees: [RepoWorktreeSizes.Item] = []
        /// The outermost paths git ignores in the project's folder. `really` is true when git ignores the path itself,
        /// not only what is inside it.
        var ignored: [(rel: String, really: Bool)] = []
        /// The build folders in the other worktrees, each with the worktree it is in.
        var builds: [(path: String, worktree: String)] = []
        var sizes: [String: Int] = [:]
        /// Xcode's DerivedData and Claude Code's chats, which live outside every checkout.
        var extra: [Item] = []
    }

    /// Returns the parts of the project, biggest first. Each ignored entry is counted without the worktrees inside it,
    /// each worktree without its builds, and the rest of the project's folder is listed as its files.
    static func parts(_ gathered: Gathered) -> [Item] {
        let inside = { (dir: String) in gathered.worktrees.filter { $0.path.hasPrefix(dir + "/") } }
        var items: [Item] = [], outside = gathered.total - inside(gathered.root).reduce(0) { $0 + $1.bytes }
        for (rel, really) in gathered.ignored {
            let path = gathered.root + "/" + rel
            guard !gathered.worktrees.contains(where: { $0.path == path }) else { continue }
            let nested = inside(path), bytes = (gathered.sizes[path] ?? 0) - nested.reduce(0) { $0 + $1.bytes }
            outside -= bytes
            let what: RepoDiskUsage.What = isBuild(path, here: gathered.here) ? .build : .ignored
            items.append(Item(path: path, bytes: bytes, what: what, removable: nested.isEmpty && really))
        }
        items.append(Item(path: gathered.root, bytes: max(0, outside), what: .files, removable: false))
        for worktree in gathered.worktrees {
            var rest = worktree.bytes
            for build in gathered.builds where build.worktree == worktree.path {
                let bytes = gathered.sizes[build.path] ?? 0
                rest -= bytes
                items.append(
                    Item(path: build.path, bytes: bytes, what: .build, removable: true, worktree: worktree.path))
            }
            items.append(Item(path: worktree.path, bytes: max(0, rest), what: .worktree, removable: worktree.removable))
        }
        return (items + gathered.extra).filter { $0.bytes >= smallest || $0.what == .files }.sorted {
            $0.bytes > $1.bytes
        }
    }

    /// Measures a project on this Mac. `root` is the project's folder as git prints it, with links resolved, and
    /// `worktrees` lists its other worktrees with their sizes (`repo.worktreeSizes`).
    static func measure(
        root: String, worktrees: [RepoWorktreeSizes.Item], remotes: Remotes, chats: URL = ClaudeHistory.defaultRoot,
        derived: URL = derivedData
    ) throws -> [Item] {
        var gathered = Gathered(root: root, worktrees: worktrees)
        let listed = try ProjectFiles.ignored(root, remotes: remotes).map(trimmed)
        gathered.ignored = kept(listed, really: try Git.ignored(listed, cwd: root, remotes: remotes))
        for worktree in worktrees {
            gathered.builds += outermost(try ProjectFiles.ignored(worktree.path, remotes: remotes).map(trimmed))
                .map { worktree.path + "/" + $0 }.filter { isBuild($0) }.map { ($0, worktree.path) }
        }
        let roots = [root] + worktrees.map(\.path), xcode = builtFor(roots, in: derived)
        let talks = roots.map { chats.appendingPathComponent(claudeName($0)).path }.filter(exists)
        gathered.sizes = try du(
            gathered.ignored.map { root + "/" + $0.rel } + gathered.builds.map(\.path) + xcode + talks)
        gathered.total = try du([root])[root] ?? 0
        gathered.extra =
            xcode.map { Item(path: $0, bytes: gathered.sizes[$0] ?? 0, what: .build, removable: true) }
            + talks.map { Item(path: $0, bytes: gathered.sizes[$0] ?? 0, what: .chats, removable: false) }
        return parts(gathered)
    }

    /// Keeps the listed paths that git ignores itself, or whose contents git doesn't also list. For example, git lists
    /// `.kelp/` along with `.kelp/artifacts/` when it ignores everything in `.kelp/`. Only the outermost of the kept
    /// paths are returned, so nothing counts twice.
    static func kept(_ listed: [String], really: Set<String>) -> [(rel: String, really: Bool)] {
        outermost(listed.filter { rel in really.contains(rel) || !listed.contains { $0.hasPrefix(rel + "/") } })
            .map { ($0, really.contains($0)) }
    }

    /// The DerivedData folders Xcode keeps for a workspace or package in one of `roots`.
    static func builtFor(_ roots: [String], in derived: URL) -> [String] {
        FileManager.default.items(in: derived).filter { dir in
            guard
                let workspace = NSDictionary(contentsOf: dir.appendingPathComponent("info.plist"))?["WorkspacePath"]
                    as? String
            else { return false }
            return roots.contains { Paths.inside(workspace, $0) }
        }.map(\.path)
    }

    /// Returns the name of the folder Claude Code keeps a folder's conversations in. The name is the folder's path with
    /// every character other than an ASCII letter or digit turned into "-".
    /// Limit: this finds chats in the default config folder and in CLAUDE_CONFIG_DIR, not in account profiles' own
    /// folders.
    static func claudeName(_ path: String) -> String {
        String(path.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
    }

    /// Returns the bytes on disk as `du` counts them, for each path that exists. One `du` measures many paths, here or
    /// on `host`. A `du` that failed (it took too long, was killed or isn't installed) fails the whole measure and is
    /// logged with what it was measuring. It isn't read as 0 bytes, because then a worktree would drop off the list and
    /// its bytes would go to the project's files.
    static func du(_ paths: [String], on host: RemoteHost? = nil) throws -> [String: Int] {
        var out: [String: Int] = [:]
        for chunk in stride(from: 0, to: paths.count, by: 256).map({ Array(paths[$0..<min($0 + 256, paths.count)]) }) {
            let data: Data
            do {
                // Exit code 1 means something couldn't be read, and the rest is still counted.
                data =
                    try host.map {
                        try $0.run("du -sk -- \(chunk.map(ShellQuote.word).joined(separator: " ")); \(Self.duEnded)")
                    } ?? Subprocess.output(["/usr/bin/du", "-sk"] + chunk, cwd: "/", ok: [0, 1])
            } catch {
                let what = chunk.count == 1 ? chunk[0] : "\(chunk.count) folders", place = host?.host ?? "this Mac"
                Log.store.error("du of \(what, privacy: .public) on \(place, privacy: .public) failed: \(error)")
                throw RPCError.internalError(
                    "\(what) wasn't measured: \((error as? ProgramError)?.message ?? error.rpcMessage)")
            }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                guard let tab = line.firstIndex(of: "\t"), let kb = Int(line[..<tab]) else { continue }
                out[String(line[line.index(after: tab)...])] = kb * 1024
            }
        }
        return out
    }

    /// The sh that runs after a `du` on a host. Exit codes 0 and 1 (something was unreadable or missing) count as an
    /// answer, and any other code ends the script with that code. `|| true` would have taken a `du` that was killed or
    /// isn't installed for folders with nothing in them.
    static let duEnded = "s=$?; [ $s -le 1 ] || exit $s"

    /// Returns the paths that aren't inside another of the given paths.
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
        if let remote = workspaces.remotes.of(repo.path) { return try measure(repo, on: remote) }
        // The worktrees are swept now, rather than taken as a hover card found them a moment ago, because Measure
        // Again calls this, and so does the tab after it moved something.
        // Limit: the tab's first measure sweeps again too, because the method doesn't say which kind of measure it is.
        return try Self.measure(
            root: Self.real(repo.path), worktrees: RepoWorktreeSizes.sizes(of: repo, workspaces, again: true),
            remotes: workspaces.remotes)
    }

    /// Moves the given paths away. Worktrees are removed the way `removeWorktrees` removes them. Anything else goes to
    /// the Trash only if it is in the project's folder or a worktree, git ignores it and tracks nothing in it, and it
    /// neither is a worktree nor contains one; or if it is DerivedData that Xcode keeps for the project. A remote
    /// project's paths are moved aside on its host (`trash(_:of:on:)`).
    func trash(_ paths: [String], of repo: Repo, derived: URL = derivedData) throws -> RepoRemoveWorktrees.Result {
        if let remote = workspaces.remotes.of(repo.path) { return try trash(paths, of: repo, on: remote) }
        let remotes = workspaces.remotes, root = Self.real(repo.path)
        let linked = try Git.linkedWorktrees(repo.path, remotes: remotes).map(\.path)
        let roots = [root] + linked, xcode = Set(Self.builtFor(roots, in: derived))
        var out = try workspaces.removeWorktrees(paths.filter(linked.contains), of: repo)
        for path in paths where !linked.contains(path) {
            // The path with links and `..` resolved, so neither can take it out of the project.
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
        // This also catches a worktree's own folder spelled differently from how git prints it (through a link or
        // `..`). A worktree goes only through `removeWorktrees` and its checks, or not at all. The check is needed
        // because a worktree in an ignored folder looks ignored, with nothing tracked in it.
        guard let held = roots.first(where: { Paths.inside($0, path) }) else { return nil }
        return Paths.inside(path, held) ? "It is a worktree." : "A worktree is inside it."
    }
}
