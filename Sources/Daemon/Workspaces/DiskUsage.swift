import AgentData
import Core
import Foundation
import GitKit

/// What a project takes on its disk (`repo.diskUsage`), and moving its parts aside (`repo.diskTrash`): on this Mac, or
/// on the host of a remote project, where git and `du` run over its connection (`DiskUsage+Host`). Handed the
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

    /// `target` is Cargo's or Maven's only beside its manifest; elsewhere it may be anything. Limit: on a host, where
    /// the manifest isn't looked for, `target` isn't taken for a build.
    static func isBuild(_ path: String, here: Bool = true) -> Bool {
        let url = URL(fileURLWithPath: path), name = url.lastPathComponent
        if buildNames.contains(name) { return true }
        let dir = url.deletingLastPathComponent().path
        return here && name == "target" && ["Cargo.toml", "pom.xml"].contains { exists(dir + "/" + $0) }
    }

    /// The project as measured, here or on its host.
    struct Gathered {
        var root = "", total = 0, here = true
        var worktrees: [RepoWorktreeSizes.Item] = []
        /// What git ignores in the project's folder, outermost, and whether git ignores it itself.
        var ignored: [(rel: String, really: Bool)] = []
        /// The builds in the other worktrees, and which worktree each is in.
        var builds: [(path: String, worktree: String)] = []
        var sizes: [String: Int] = [:]
        /// Xcode's DerivedData and Claude Code's chats: outside every checkout.
        var extra: [Item] = []
    }

    /// The parts, biggest first: each ignored entry less the worktrees in it, each worktree less its builds, and the
    /// rest of the folder as its files.
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

    /// On this Mac. `root` is the project's folder as git prints it (links resolved); `worktrees` its other worktrees
    /// with their sizes (`repo.worktreeSizes`).
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

    /// Of what git lists, those it ignores itself or whose contents it doesn't list too (it lists `.kelp/` along with
    /// `.kelp/artifacts/` when it ignores everything in it); then the outermost, so nothing counts twice.
    static func kept(_ listed: [String], really: Set<String>) -> [(rel: String, really: Bool)] {
        outermost(listed.filter { rel in really.contains(rel) || !listed.contains { $0.hasPrefix(rel + "/") } })
            .map { ($0, really.contains($0)) }
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

    /// Blocks on disk as `du` counts them, for each path that's there; one program for many paths, here or on `host`.
    /// A `du` that failed (took too long, was killed, isn't there) fails the measure and is logged with what it was
    /// measuring: read as 0 bytes, a worktree dropped off the list and its bytes went to the project's files.
    static func du(_ paths: [String], on host: RemoteHost? = nil) throws -> [String: Int] {
        var out: [String: Int] = [:]
        for chunk in stride(from: 0, to: paths.count, by: 256).map({ Array(paths[$0..<min($0 + 256, paths.count)]) }) {
            let data: Data
            do {
                // 1: something in it couldn't be read; the rest is counted.
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

    /// sh after a host's `du`: 0 and 1 (something unreadable or not there) are an answer; anything else ends the
    /// script with it, where `|| true` took a `du` that was killed or isn't installed for folders with nothing in them.
    static let duEnded = "s=$?; [ $s -le 1 ] || exit $s"

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
        if let remote = workspaces.remotes.of(repo.path) { return try measure(repo, on: remote) }
        // Swept now, not as a hover card found them a moment ago: Measure Again asks this, and so does the tab once
        // it moved something. Limit: so does its first measure; the method doesn't say which it is.
        return try Self.measure(
            root: Self.real(repo.path), worktrees: RepoWorktreeSizes.sizes(of: repo, workspaces, again: true),
            remotes: workspaces.remotes)
    }

    /// Worktrees as `removeWorktrees` takes them; anything else to the Trash only if it's in the project's folder or a
    /// worktree, git ignores it and tracks nothing in it, and it neither is a worktree nor has one inside; or it's
    /// DerivedData Xcode keeps for the project. A remote project's go aside on its host (`trash(_:of:on:)`).
    func trash(_ paths: [String], of repo: Repo, derived: URL = derivedData) throws -> RepoRemoveWorktrees.Result {
        if let remote = workspaces.remotes.of(repo.path) { return try trash(paths, of: repo, on: remote) }
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
        // A worktree's own folder too, spelled other than git prints it (a link, `..`): it goes as `removeWorktrees`
        // takes it, with its checks, or not at all. In an ignored folder it's ignored with nothing tracked in it.
        guard let held = roots.first(where: { Paths.inside($0, path) }) else { return nil }
        return Paths.inside(path, held) ? "It is a worktree." : "A worktree is inside it."
    }
}
