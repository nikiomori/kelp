import Core
import Foundation

extension Git {
    /// The linked worktree `dir` is in (its top folder, which holds a `.git` file), when that worktree belongs to the
    /// same repository as `folder` and isn't `folder`'s own checkout: an agent's branch of its own (Claude Code's
    /// `.claude/worktrees/…`). Read off the files alone, no git run, because each of an agent's hooks asks it.
    public static func linkedWorktree(containing dir: String, besides folder: String) -> String? {
        guard let here = checkout(dir), here.linked, let home = checkout(folder), here.top != home.top,
            let repository = commonDir(here.top)?.resolvingSymlinksInPath(),
            repository == commonDir(home.top)?.resolvingSymlinksInPath()
        else { return nil }
        return here.top
    }

    /// The branch a checkout has out, read from its HEAD file; nil while HEAD is detached or can't be read.
    public static func headBranch(_ folder: String) -> String? {
        guard let checkout = checkout(folder), let gitDir = gitDir(checkout.top),
            let data = FileManager.default.contents(atPath: gitDir.path + "/HEAD"),
            let head = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            head.hasPrefix("ref: refs/heads/")
        else { return nil }
        return String(head.dropFirst("ref: refs/heads/".count))
    }

    /// The repositories directly inside `folder`, by folder name and in name order, when `folder` itself isn't in one:
    /// a project made of several repositories side by side (`RepoKey`). A folder that links to a repository counts.
    /// Hidden folders don't. Read off the files alone, no git run, because each read of the folder's git asks it.
    /// Limit: a remote project's folder here holds only its marker, so it holds no repositories.
    public static func nestedRepos(_ folder: String) -> [String] {
        guard checkout(folder) == nil,
            let top = FileManager.default.enumerator(
                at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles])
        else { return [] }
        return top.compactMap { ($0 as? URL)?.lastPathComponent }.filter { name in
            FileManager.default.fileExists(atPath: folder + "/" + name + "/.git")
        }.sorted()
    }

    /// A main checkout's default branch read off its files, as `defaultBranch` asks git: origin's HEAD, else main or
    /// master where one is there, else the branch checked out. No git runs, because a folder of repositories
    /// (`RepoKey`) names each one's base wherever its project's is read.
    public static func defaultBranchFromFiles(_ repo: String) -> String {
        let git = repo + "/.git/"
        func text(_ file: String) -> String {
            FileManager.default.contents(atPath: git + file).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        let packed = text("packed-refs"), origin = text("refs/remotes/origin/HEAD")
        if origin.hasPrefix("ref: refs/remotes/origin/") {
            return origin.dropFirst("ref: refs/remotes/origin/".count).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let local = ["main", "master"].first {
            FileManager.default.fileExists(atPath: git + "refs/heads/" + $0) || packed.contains(" refs/heads/\($0)\n")
        }
        return local ?? headBranch(repo) ?? "main"
    }

    /// The top folder of the checkout `path` is in, and whether it is a linked worktree (its `.git` is a file).
    private static func checkout(_ path: String) -> (top: String, linked: Bool)? {
        var url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        while url.path != "/" {
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path, isDirectory: &isFolder) {
                // Resolved here, where the folder is there: a path under it that isn't (a hook's cwd) resolves no link.
                return (url.resolvingSymlinksInPath().path, !isFolder.boolValue)
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    /// The git folder of the checkout whose top folder is `top`: its `.git` folder, or the one its `.git` file points
    /// at (a linked worktree's, a submodule's). nil when there is no `.git` or its file names no folder.
    static func gitDir(_ top: String) -> URL? {
        let dotGit = URL(fileURLWithPath: top).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return dotGit }
        guard let text = String(contentsIfAny: dotGit), text.hasPrefix("gitdir: ") else { return nil }
        let pointed = text.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: pointed, relativeTo: URL(fileURLWithPath: top, isDirectory: true))
            .standardizedFileURL
    }

    /// The git folder that all of a repository's worktrees share, where its config, refs and `info/exclude` live, for
    /// the checkout whose top folder is `top`: its git folder, or the one that folder's `commondir` file names.
    public static func commonDir(_ top: String) -> URL? {
        guard let gitDir = gitDir(top) else { return nil }
        guard let common = String(contentsIfAny: gitDir.appendingPathComponent("commondir")) else { return gitDir }
        return URL(fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: gitDir)
            .standardizedFileURL
    }

    /// The host of the repository's `origin` (github.com) for the repository `cwd` is in: where `git push` and `gh`
    /// go. Read off its config file, no git runs.
    public static func originHost(_ cwd: String) -> String? {
        guard let file = RepoFilters.configFile(cwd), let config = String(contentsIfAny: URL(fileURLWithPath: file))
        else {
            return nil
        }
        var inOrigin = false
        for line in config.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("[") { inOrigin = line == "[remote \"origin\"]" }
            if inOrigin, line.hasPrefix("url"), let eq = line.firstIndex(of: "=") {
                return host(ofRemote: line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// The host in a remote's URL: `git@github.com:o/r.git`, `https://github.com/o/r`, `ssh://git@host:22/r`.
    static func host(ofRemote url: String) -> String? {
        if let parsed = URL(string: url), let host = parsed.host, !host.isEmpty { return host }
        guard let colon = url.firstIndex(of: ":"), !url.hasPrefix("/") else { return nil }
        return url[..<colon].split(separator: "@").last.map(String.init)
    }
}
