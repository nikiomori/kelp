import Core
import Foundation
import GRDB
import GitKit

// comment.*: review comments on a diff, kept, marked and sent to the agent as one message.

extension CommentAdd: Handled {
    var reportsFor: String? { session }   // a comment names its own session's agent as author, not another's
    var signs: Bool { true }
    func handle(_ scm: SourceControl) throws -> DiffComment {
        // A path is one line: one with a break in it would be drawn under no file, and sent as lines of its own.
        guard !file.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 0x20 } == true }) else {
            throw RPCError.invalidParams("A file's path has no line breaks or control characters.")
        }
        let workspace = try scm.store.worktree(named: id)
        let on = try clientRef(commit) ?? "HEAD"
        let full = try Git.run(
            ["rev-parse", "--verify", "-q", on + "^{commit}"], cwd: workspace.path, ok: [0, 1],
            remotes: scm.remotes
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)   // empty before the first commit
        if commit != nil, full.isEmpty { throw RPCError.invalidParams("No commit \(on) here.") }
        let head = String(full.prefix(12))
        let agent = session.flatMap { scm.sessions.existing($0)?.snapshot.agent }.flatMap {
            $0 == "shell" || $0 == "custom" ? nil : $0
        }
        // A program in a terminal (an agent typed into it, a script) is named too: only the window's own comments are the
        // user's, unframed when they're sent.
        let author =
            try agent.map { try scm.sessions.setup.manifest($0, command: nil).name }
            ?? session.map { _ in String(localized: "A program in a terminal") }
        let comment = DiffComment(
            worktreeId: workspace.id, file: file, startLine: start ?? 1, endLine: end ?? start ?? 1, quote: quote ?? "",
            text: text,
            side: side == "old" ? "old" : nil, commit: head.isEmpty ? nil : head, author: author,
            onCommit: commit == nil ? nil : full)
        try scm.store.save(comment)
        return comment
    }
}
extension CommentList: Handled {
    func handle(_ scm: SourceControl) throws -> Result { try scm.store.comments(worktree: id) }
}
extension CommentSetState: Handled {
    func handle(_ scm: SourceControl) throws -> Done {
        guard var comment = try scm.store.db.read({ try DiffComment.fetchOne($0, key: id) }) else {
            throw RPCError.invalidParams("no comment")
        }
        comment.state = DiffComment.State(rawValue: state) ?? .open
        try scm.store.save(comment)
        return Done()
    }
}
/// All open comments → one message into the agent's terminal.
extension CommentSend: Handled {
    var actsOn: String? { session }   // it types, with Enter: an agent sends only to itself and the sessions it started
    var typesInto: String? { session }   // a send (`SessionSend`, whose handler it calls past `allow`): not into a question
    func handle(_ scm: SourceControl) throws -> Int {
        let workspace = try scm.store.worktree(named: id)
        // Into an agent only: a shell would run each line of the message (another agent's findings, quoted code).
        // Its record, not only a running one: a paused agent is one too, and the send wakes it.
        guard
            try (scm.sessions.existing(session)?.snapshot ?? scm.store.session(session))?.isAgent == true
        else {
            throw RPCError.invalidParams("Comments go to an agent, not to a terminal.")
        }
        let wanted = only.map(Set.init)
        // Taken as it's marked sent, in one write: a second send at once (a double click, the CLI beside the window) finds
        // none of these open and types them in no second time. Put back if the send fails.
        let open = try scm.store.db.write { db -> [DiffComment] in
            let open = try DiffComment.filter(Column("worktreeId") == workspace.id).fetchAll(db)
                .filter { $0.state == .open && wanted?.contains($0.id) != false }
            for var comment in open {
                comment.state = .sent
                try comment.update(db)
            }
            return open
        }
        guard !open.isEmpty else { return 0 }
        do {
            _ = try SessionSend(id: session, text: Self.message(branch: workspace.branch, comments: open)).handle(
                scm.sessions)
        } catch {
            // Open again, those still sent (not one set otherwise meanwhile, nor one gone with its workspace); the send's
            // error is what's told, whatever this does.
            let ids = open.map(\.id)
            Log.store.attempt("putting back comments that weren't sent") {
                _ = try scm.store.db.write { db in
                    try DiffComment.filter(
                        ids.contains(Column("id")) && Column("state") == DiffComment.State.sent.rawValue
                    )
                    .updateAll(db, Column("state").set(to: DiffComment.State.open.rawValue))
                }
            }
            throw error
        }
        return open.count
    }

    /// File, lines, code quote, remark for each.
    private static func message(branch: String, comments: [DiffComment]) -> String {
        var body = "Review comments on branch \(branch). Please address each one:\n"
        for (index, comment) in comments.enumerated() {
            let range =
                comment.startLine == comment.endLine
                ? "\(comment.startLine)" : "\(comment.startLine)-\(comment.endLine)"
            let removed = comment.side == "old" ? " (removed lines, numbered as in the file before this change)" : ""
            let past = comment.onCommit.map { " (in commit \($0.prefix(12)), not the current changes)" } ?? ""
            var entry = "\(comment.file):\(range)\(removed)\(past)\n"
            for line in comment.quote.split(separator: "\n", omittingEmptySubsequences: false) {
                entry += "   > \(line)\n"
            }
            entry += "   " + comment.text
            // Another agent's finding is data to weigh, not the user's word: it may quote what a pull request said. All
            // of it, where and what it quotes too: each is what that agent wrote.
            body +=
                "\n\(index + 1). " + (comment.author.map { Untrusted.frame(entry, what: "\($0)'s finding") } ?? entry)
                + "\n"
        }
        return body
    }
}

extension Methods {
    static let commentMethods: [any Answered.Type] = [
        CommentAdd.self, CommentList.self, CommentSetState.self, CommentSend.self
    ]
}
