import Core
import Foundation
import GitKit

extension CommitPlanAdd: Handled {
    static var quick: Bool { true }
    var reportsFor: String? { session }   // a plan names its own session's agent, not another's
    func handle(_ workspaces: Workspaces) throws -> Int {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = files.filter { !$0.isEmpty }
        guard !paths.isEmpty, !text.isEmpty else {
            throw RPCError.invalidParams("A commit needs at least one file and a message: kelp commit add <file>… -m …")
        }
        // A path is one line: one with a break in it names no file the panel shows.
        guard !paths.contains(where: { $0.contains(where: \.isNewline) }) else {
            throw RPCError.invalidParams("A file's path has no line breaks.")
        }
        _ = try workspaces.store.worktree(named: worktreeId)
        let commit = PlannedCommit(files: paths, message: text)
        return workspaces.commitPlans.withLock { plans in
            plans[worktreeId, default: []].append(commit)
            return plans[worktreeId]?.count ?? 0
        }
    }
}

extension CommitPlanTake: Handled {
    static var quick: Bool { true }
    func handle(_ workspaces: Workspaces) throws -> [PlannedCommit] {
        workspaces.commitPlans.withLock { $0.removeValue(forKey: worktreeId) ?? [] }
    }
}

extension GitCommitPaths: Handled {
    func handle(_ scm: SourceControl) throws -> String {
        try Git.commit(scm.folder(worktreeId), files: files, message: message, remotes: scm.remotes)
    }
}

extension GitUndoCommits: Handled {
    func handle(_ scm: SourceControl) throws -> Done {
        try Git.undoCommits(scm.folder(worktreeId), head: head, count: count, remotes: scm.remotes)
        return Done()
    }
}

extension Methods {
    static let commitPlanMethods: [any Answered.Type] = [
        CommitPlanAdd.self, CommitPlanTake.self, GitCommitPaths.self, GitUndoCommits.self
    ]
}
