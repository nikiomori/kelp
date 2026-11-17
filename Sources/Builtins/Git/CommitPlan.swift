import Core

/// What an agent proposed for a workspace's changes, oldest commit first, as the user edits it before Kelp makes the
/// commits. Each file goes whole into one commit at most, and a file in no commit stays uncommitted.
struct CommitPlan: Equatable {
    struct Commit: Equatable {
        var message: String
        var files: [String]
    }
    /// The name of the agent that wrote the plan.
    var agent: String
    var commits: [Commit]

    /// Holds the agent's commits to the files that are changed (`changed`), each file in the first commit that names
    /// it. A commit left with no file is dropped.
    init(agent: String, proposed: [PlannedCommit], changed: [String]) {
        self.agent = agent
        let known = Set(changed)
        var seen = Set<String>()
        commits = proposed.compactMap { p in
            let files = p.files.filter { known.contains($0) && seen.insert($0).inserted }
            return files.isEmpty ? nil : Commit(message: p.message, files: files)
        }
    }

    /// The number of the commit `file` goes into, counted from 1 as the rows show it.
    func number(of file: String) -> Int? { commits.firstIndex { $0.files.contains(file) }.map { $0 + 1 } }

    /// Every file of the plan, in the order its commits take them.
    var files: [String] { commits.flatMap(\.files) }

    /// Moves `file` into commit `index`, counted from 0, or out of every commit when `index` is nil. `commits.count`
    /// starts a new commit, whose message the user writes. A commit left with no file is dropped.
    mutating func move(_ file: String, to index: Int?) {
        if let index, commits.indices.contains(index), commits[index].files.contains(file) { return }
        let target = index.map { $0 < commits.count ? commits[$0].files.first : nil }
        for i in commits.indices { commits[i].files.removeAll { $0 == file } }
        switch (index, target) {
        case (nil, _): break
        case (_, .some(let anchor?)):   // the commit it was dropped on, wherever that sits once `file` left another
            if let index = commits.firstIndex(where: { $0.files.contains(anchor) }) {
                commits[index].files.append(file)
            }
        default: commits.append(Commit(message: "", files: [file]))
        }
        commits.removeAll { $0.files.isEmpty }
    }

    /// Merges the plan into one commit of every file, with the messages one after another.
    mutating func merge() {
        guard commits.count > 1 else { return }
        commits = [Commit(message: commits.map(\.message).joined(separator: "\n\n"), files: files)]
    }
}
