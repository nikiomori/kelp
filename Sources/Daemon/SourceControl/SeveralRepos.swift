import Core
import Foundation
import GitKit

// Source control in a folder that holds several repositories side by side (`RepoKey`): what a git method on the folder
// does in each repository. The handlers route each file to its repository (`SourceControl.places`) and come here for
// what acts on all of them.

extension SourceControl {
    /// One message makes a commit in each repository that has something to commit: what is staged there, or with
    /// `all` every change. Returns each one's name and hash. A failure in one doesn't stop the others, and its error
    /// names the commits that were made, since they stay.
    func commitInEach(_ folder: String, _ names: [String], message: String, all: Bool, amend: Bool) throws -> String {
        guard !amend else {
            throw RPCError.invalidParams("Amend in one repository at a time: this folder holds several.")
        }
        var made: [String] = [], failed: [String] = []
        for name in names {
            let repo = folder + "/" + name
            do {
                let changes = try Git.status(repo, remotes: remotes)
                guard all ? !changes.isEmpty : changes.contains(where: { $0.staged && !$0.conflicted }) else {
                    continue
                }
                made.append(name + " " + (try Git.commit(repo, message: message, all: all, remotes: remotes)))
            } catch { failed.append("\(name): \((error as? GitError)?.message ?? "\(error)")") }
        }
        guard failed.isEmpty else {
            let committed = made.isEmpty ? [] : ["Committed in " + made.joined(separator: ", ") + "."]
            throw RPCError.invalidParams((committed + failed).joined(separator: "\n"))
        }
        guard !made.isEmpty else { throw RPCError.invalidParams("None of the folder's repositories has changes.") }
        return made.joined(separator: ", ")
    }

    /// A pull where a repository follows a remote branch, a push where it has something to send (a branch with nothing
    /// of its own isn't published), a fetch in each. A failure in one doesn't stop the others; all are said at the end.
    func remoteInEach(_ folder: String, _ names: [String], _ op: GitRemoteOp.Step) throws {
        let base = { Git.defaultBranch(repo: $0, remotes: remotes) }
        var failed: [String] = []
        for name in names {
            let repo = folder + "/" + name
            do {
                switch op {
                case .pull where !Git.hasUpstream(repo, remotes: remotes): continue
                case .push where try !Git.hasWorkToPush(repo, base: base(repo), remotes: remotes): continue
                default: try Git.remote(repo, op, remotes: remotes)
                }
            } catch { failed.append("\(name): \((error as? GitError)?.message ?? "\(error)")") }
        }
        guard failed.isEmpty else { throw RPCError.invalidParams(failed.joined(separator: "\n")) }
    }
}

extension GitDiff {
    /// The diff in a folder of repositories (`RepoKey`): the file's own repository, or each one's, its paths under its
    /// name. A branch's diff runs from each repository's own base unless one was given.
    func several(_ scm: SourceControl, _ dir: String, _ src: DiffSource) throws -> Result {
        func diff(_ folder: String, _ file: String?) throws -> Result {
            var src = src
            if case .branch = src, base == nil { src = .branch(base: Git.defaultBranch(repo: folder, remotes: .none)) }
            return try Git.diff(
                folder, source: src, file: file, ignoreSpace: ignoreSpace == true, context: context ?? 3,
                remotes: scm.remotes
            ).map { $0.under((folder as NSString).lastPathComponent) }
        }
        if let file {
            let (folder, rest) = try scm.place(dir, file)
            return try diff(folder, rest)
        }
        return try scm.each(dir) { try diff($0, nil) }.flatMap(\.value)
    }
}

extension FileChange {
    /// The change as a folder of repositories names it: under its repository's name (`RepoKey`), or as it is.
    func under(_ name: String?) -> FileChange {
        name.map { FileChange(path: $0 + "/" + path, index: index, worktree: worktree) } ?? self
    }
}

extension FileDiff {
    /// The diff as a folder of repositories names it. Its header stays as git wrote it, for patches applied in the
    /// repository.
    func under(_ name: String?) -> FileDiff {
        var diff = self
        if let name { diff.path = name + "/" + path }
        return diff
    }
}
