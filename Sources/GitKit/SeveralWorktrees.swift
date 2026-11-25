import Core
import Foundation

// A branch for a folder of repositories (`RepoKey`): one folder holding a worktree of each repository, side by side and
// named as they are, so an agent started there sees all of them on the branch.
extension Git {
    /// Makes `branch` in each repository `project` holds, each from its own base branch, as worktrees in one
    /// new folder under `dir`, and returns that folder. What else `project` holds (prd/, notes) is linked from there,
    /// since it isn't versioned and is the same for every branch. Each worktree gets its repository's own files
    /// (`copyFiles`, `.worktreeinclude`) as `addWorktree` gives them. If one fails, the ones made before it go again.
    public static func addWorktrees(
        project: String, branch: String, into dir: URL, copyFiles: [String], remotes: Remotes
    ) throws -> String {
        let repos = nestedRepos(project)
        var path = dir.appendingPathComponent(slug(branch)).path, n = 2
        while FileManager.default.fileExists(atPath: path) {
            path = dir.appendingPathComponent("\(slug(branch))-\(n)").path
            n += 1
        }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        var made: [String] = []
        do {
            for name in repos {
                let repo = project + "/" + name, worktree = path + "/" + name
                let base = defaultBranch(repo: repo, remotes: remotes)
                try run(["worktree", "add", "-b", rev(branch), worktree, rev(base)], cwd: repo, remotes: remotes)
                made.append(name)
                let files = Array(Set(copyFiles + includedIgnoredFiles(repo: repo, remotes: remotes)))
                place(files, repo: repo, worktree: worktree) { src, dst in
                    gitLog.attempt("copying \(src) into the new worktree") {
                        try FileManager.default.copyItem(atPath: src, toPath: dst)
                    }
                }
            }
        } catch {
            gitLog.attempt("taking back the worktrees made for \(branch)") {
                for name in made {
                    try removeWorktree(
                        repo: project + "/" + name, path: path + "/" + name, branch: branch, force: true,
                        remotes: remotes)
                }
                try FileManager.default.removeItem(atPath: path)
            }
            throw error
        }
        gitLog.attempt("linking what isn't a repository into \(path)") {
            for name in try FileManager.default.contentsOfDirectory(atPath: project)
            where !name.hasPrefix(".") && !repos.contains(name) {
                try FileManager.default.createSymbolicLink(
                    atPath: path + "/" + name, withDestinationPath: project + "/" + name)
            }
        }
        return path
    }

    /// Where a workspace's git is: `project`'s repository with `folder`, or in a folder of repositories each of them
    /// with its worktree in `folder` (`addWorktrees`).
    public static func checkouts(project: String, folder: String) -> [(repo: String, folder: String)] {
        let names = nestedRepos(project)
        return names.isEmpty ? [(project, folder)] : names.map { (project + "/" + $0, folder + "/" + $0) }
    }

    /// Renames the branch in each of `folders` (a folder of repositories' worktrees); when one fails, the ones before
    /// it get the old name back.
    public static func renameBranch(in folders: [String], from old: String, to new: String, remotes: Remotes) throws {
        for (index, folder) in folders.enumerated() {
            do { try renameBranch(folder, from: old, to: new, remotes: remotes) } catch {
                gitLog.attempt("giving \(new) its name back") {
                    for done in folders.prefix(index) { try renameBranch(done, from: new, to: old, remotes: remotes) }
                }
                throw error
            }
        }
    }

    /// What `removeWorktrees` would refuse, without removing anything.
    public static func checkRemovable(
        project: String, path: String, branch: String?, force: Bool, dropCommits: Bool = false, remotes: Remotes
    ) throws {
        let repos = nestedRepos(project)
        for name in repos where FileManager.default.fileExists(atPath: path + "/" + name) {
            try checkRemovable(
                repo: project + "/" + name, path: path + "/" + name, branch: branch, force: force,
                dropCommits: dropCommits, remotes: remotes)
        }
    }

    /// Removes a folder `addWorktrees` made: each repository's worktree and branch as `removeWorktree` removes them,
    /// once all of them may go (nothing is removed if one may not), then the folder with its links. A worktree whose
    /// folder is gone already is forgotten as `forgetWorktree` does.
    public static func removeWorktrees(
        project: String, path: String, branch: String?, force: Bool, dropCommits: Bool = false, remotes: Remotes
    ) throws {
        let repos = nestedRepos(project)
        try checkRemovable(
            project: project, path: path, branch: branch, force: force, dropCommits: dropCommits, remotes: remotes)
        let here = repos.filter { FileManager.default.fileExists(atPath: path + "/" + $0) }
        for name in repos {
            let repo = project + "/" + name, folder = path + "/" + name
            if here.contains(name) {
                try removeWorktree(
                    repo: repo, path: folder, branch: branch, force: force, dropCommits: dropCommits, remotes: remotes)
            } else {
                try forgetWorktree(repo: repo, path: folder, branch: branch, dropCommits: dropCommits, remotes: remotes)
            }
        }
        if FileManager.default.fileExists(atPath: path) { try Trash.move(URL(fileURLWithPath: path)) }
    }
}
