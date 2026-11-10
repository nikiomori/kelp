import Core
import Foundation

extension Git {
    public static func stage(_ path: String, files: [String], remotes: Remotes) throws {
        try run(["add", "--"] + literal(files), cwd: path, remotes: remotes)
    }
    public static func unstage(_ path: String, files: [String], remotes: Remotes) throws {
        try run(["reset", "-q", "HEAD", "--"] + literal(files), cwd: path, remotes: remotes)
    }

    /// Stage (or unstage, `reverse`) a single hunk of `diff` via `git apply --cached`.
    public static func applyHunk(_ path: String, diff: FileDiff, hunk: Int, reverse: Bool, remotes: Remotes)
        throws
    {
        try runData(
            ["apply", "--cached", "--recount", "--unidiff-zero"] + (reverse ? ["-R"] : []) + ["-"], cwd: path,
            stdin: diff.patch(hunk: hunk), remotes: remotes)
    }

    /// Throw away one unstaged hunk of `diff` (the working tree's version of `git restore -p`): its reverse, applied to the files.
    public static func discardHunk(_ path: String, diff: FileDiff, hunk: Int, remotes: Remotes) throws {
        try runData(
            ["apply", "--recount", "--unidiff-zero", "-R", "-"], cwd: path, stdin: diff.patch(hunk: hunk),
            remotes: remotes)
    }

    /// `all`: every change, new files too (what "Commit N Files" counts), not just what's staged. Never with unresolved
    /// conflicts: staging them would commit the conflict markers.
    @discardableResult
    public static func commit(
        _ path: String, message: String, all: Bool = false, amend: Bool = false, remotes: Remotes
    ) throws -> String {
        if all {
            if try status(path, remotes: remotes).contains(where: \.conflicted) {
                throw GitError.refused("Resolve the merge conflicts before committing.")
            }
            try run(["add", "-A"], cwd: path, remotes: remotes)
        }
        try run(["commit", "-q"] + (amend ? ["--amend"] : []) + ["-m", message], cwd: path, remotes: remotes)
        return try line(["rev-parse", "--short", "HEAD"], cwd: path, remotes: remotes)
    }

    public struct MergeResult: Sendable, Equatable {
        public var merged: Bool
        public var conflicts: [String]
    }

    /// A merge is under way in this checkout (MERGE_HEAD exists): its conflicts and resolutions are the user's.
    public static func isMerging(_ path: String, remotes: Remotes) -> Bool {
        succeeds(["rev-parse", "-q", "--verify", "MERGE_HEAD"], cwd: path, remotes: remotes)
    }

    /// Merge `branch` into the branch checked out in `target` (usually the main checkout). Aborts on conflict
    /// unless `keepConflicts`, so the caller can show them and hand them to an agent.
    /// `onto`: the branch `target` must have checked out (the base); anything else is refused rather than merged into.
    public static func merge(
        branch: String, into target: String, onto: String? = nil, keepConflicts: Bool = false,
        remotes: Remotes
    ) throws -> MergeResult {
        if let onto {
            let here = try currentBranch(target, remotes: remotes)
            guard here == onto else {
                throw GitError.refused("The main checkout is on \(here), not \(onto): switch it back to \(onto) first")
            }
            guard branch != onto else {
                throw GitError.refused("\(branch) is the branch being merged into")
            }
        }
        // Only a merge started here is ever aborted here: one the user had under way is refused, untouched.
        guard !isMerging(target, remotes: remotes) else {
            throw GitError.refused("A merge is already in progress in \(target)")
        }
        do {
            try run(["merge", "--no-edit", rev(branch)], cwd: target, remotes: remotes)
            return MergeResult(merged: true, conflicts: [])
        } catch {
            let conflicts = try status(target, remotes: remotes).filter(\.conflicted).map(\.path)
            if conflicts.isEmpty { throw error }
            if !keepConflicts { try run(["merge", "--abort"], cwd: target, remotes: remotes) }
            return MergeResult(merged: false, conflicts: conflicts)
        }
    }

    public static func log(_ path: String, base: String? = nil, limit: Int = 50, remotes: Remotes) throws -> [(
        hash: String, subject: String
    )] {
        let range = try base.map { ["\(try rev($0))..HEAD"] } ?? []
        return try run(["log", "--format=%h%x09%s", "-n\(limit)"] + range, cwd: path, remotes: remotes)
            .split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 1)
                return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
            }
    }
}
