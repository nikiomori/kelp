import Core
import Foundation
import GitKit
import os

/// The commits that agents proposed (`kelp commit add`), by workspace, until the window takes them. They are kept in
/// memory only, as a commit message being written is.
final class CommitPlans: Sendable {
    let store: Store
    let plans = OSAllocatedUnfairLock(initialState: [String: [PlannedCommit]]())
    init(store: Store) { self.store = store }
}

extension CommitPlanAdd: Handled {
    // An agent proposes commits (`kelp commit add`). The user edits them and Kelp makes them, never the agent.
    static let agents = AgentAccess.acts
    static var quick: Bool { true }
    var fence: Fence { Fence(reportsFor: session) }   // a plan names its own session's agent, not another's
    func handle(_ commits: CommitPlans) throws -> Int {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = files.filter { !$0.isEmpty }
        guard !paths.isEmpty, !text.isEmpty else {
            throw RPCError.invalidParams("A commit needs at least one file and a message: kelp commit add <file>… -m …")
        }
        // A path must be one line, because a path with a break in it names no file the panel shows.
        guard !paths.contains(where: { $0.contains(where: \.isNewline) }) else {
            throw RPCError.invalidParams("A file's path has no line breaks.")
        }
        _ = try commits.store.worktree(named: worktreeId)
        let commit = PlannedCommit(files: paths, message: text)
        return commits.plans.withLock { plans in
            plans[worktreeId, default: []].append(commit)
            return plans[worktreeId]?.count ?? 0
        }
    }
}

extension CommitPlanTake: Handled {
    static var quick: Bool { true }
    func handle(_ commits: CommitPlans) throws -> [PlannedCommit] {
        commits.plans.withLock { $0.removeValue(forKey: worktreeId) ?? [] }
    }
}

extension GitCommitPaths: Handled {
    func handle(_ scm: SourceControl) throws -> String {
        // In a folder of repositories (`RepoKey`), a commit in each repository the files are in, by name and hash.
        let folder = try scm.folder(worktreeId)
        guard scm.repos(in: folder) != nil else {
            return try Git.commit(folder, files: files, message: message, remotes: scm.remotes)
        }
        return try scm.places(folder, files).map { place in
            (place.folder as NSString).lastPathComponent + " "
                + (try Git.commit(place.folder, files: place.files, message: message, remotes: scm.remotes))
        }.joined(separator: ", ")
    }
}

extension GitUndoCommits: Handled {
    func handle(_ scm: SourceControl) throws -> Done {
        let folder = try scm.folder(worktreeId)
        guard scm.repos(in: folder) == nil else {
            throw RPCError.invalidParams("Undo the commits in each repository: this folder holds several.")
        }
        try Git.undoCommits(folder, head: head, count: count, remotes: scm.remotes)
        return Done()
    }
}

extension Methods {
    static let commitPlanMethods: [any Answered.Type] = [
        CommitPlanAdd.self, CommitPlanTake.self, GitCommitPaths.self, GitUndoCommits.self
    ]
}
