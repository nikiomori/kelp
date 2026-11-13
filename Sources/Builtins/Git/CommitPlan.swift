import Core

/// What an agent proposed for a workspace's changes, as the user edits it before Kelp makes the commits, oldest first:
/// each file whole and in one commit at most; a file in none stays uncommitted.
struct CommitPlan: Equatable {
    struct Commit: Equatable {
        var message: String
        var files: [String]
    }
    /// Who wrote it, by name.
    var agent: String
    var commits: [Commit]

    /// The agent's commits held to the files that are changed (`changed`), each file in the first commit naming it; a
    /// commit left with no file goes.
    init(agent: String, proposed: [PlannedCommit], changed: [String]) {
        self.agent = agent
        let known = Set(changed)
        var seen = Set<String>()
        commits = proposed.compactMap { p in
            let files = p.files.filter { known.contains($0) && seen.insert($0).inserted }
            return files.isEmpty ? nil : Commit(message: p.message, files: files)
        }
    }

    /// The commit `file` goes into, counted from 1 as the rows show it.
    func number(of file: String) -> Int? { commits.firstIndex { $0.files.contains(file) }.map { $0 + 1 } }

    /// Every file of the plan, in the order its commits make them.
    var files: [String] { commits.flatMap(\.files) }

    /// `file` into commit `index` (from 0; `commits.count` starts a new one, its message to write), or out of every one
    /// (nil). A commit left with no file goes.
    mutating func move(_ file: String, to index: Int?) {
        if let index, commits.indices.contains(index), commits[index].files.contains(file) { return }
        let target = index.map { $0 < commits.count ? commits[$0].files.first : nil }
        for i in commits.indices { commits[i].files.removeAll { $0 == file } }
        switch (index, target) {
        case (nil, _): break
        case (_, .some(let anchor?)):   // the commit it was dropped on, wherever it sits once `file` left another
            if let i = commits.firstIndex(where: { $0.files.contains(anchor) }) { commits[i].files.append(file) }
        default: commits.append(Commit(message: "", files: [file]))
        }
        commits.removeAll { $0.files.isEmpty }
    }

    /// One commit of every file, the messages one after another.
    mutating func merge() {
        guard commits.count > 1 else { return }
        commits = [Commit(message: commits.map(\.message).joined(separator: "\n\n"), files: files)]
    }
}
