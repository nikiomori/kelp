import Core
import Foundation
import GRDB
import GitKit

// The comment.* methods keep review comments on a diff, mark them, and send them to the agent as one message.

extension CommentAdd: Handled {
    static let agents = AgentAccess.acts
    var fence: Fence { Fence(reportsFor: session, signs: true) }   // names its own session's agent as the author
    func handle(_ scm: SourceControl) throws -> DiffComment {
        // A path must be one line. A path with a break in it would be drawn under no file, and sent as lines of its
        // own.
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
        let agent = session.flatMap { scm.live[$0]?.snapshot.agent }.flatMap {
            Session.isAgent($0) ? $0 : nil
        }
        // A program in a terminal (an agent that typed into it, or a script) is named as the author too, because only
        // comments made in the window are the user's, and only those are sent without a frame.
        let author =
            try agent.map { try scm.setup.manifest($0, command: nil).name }
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
    static let agents = AgentAccess.reads
    func handle(_ scm: SourceControl) throws -> Result {
        let workspace = try scm.store.worktree(named: id)
        return try CommentPlaces.follow(try scm.store.comments(worktree: workspace.id), in: workspace.path, scm)
    }
}

/// Keeps a comment on the folder's changes on the lines it quotes. When an agent's edit above those lines moves them
/// down, the comment moves with them, and the move is saved. When the lines appear more than once, the comment goes to
/// the nearest copy. When the lines are gone, the comment stays where it was.
/// Limit: only for a project on this Mac, because a remote project's files would be read over ssh on every look.
enum CommentPlaces {
    static func follow(_ comments: [DiffComment], in folder: String, _ scm: SourceControl) throws -> [DiffComment] {
        guard scm.remotes.of(folder) == nil else { return comments }
        var files: [String: [String]] = [:], out: [DiffComment] = []
        for var comment in comments {
            defer { out.append(comment) }
            guard comment.state != .resolved, comment.onCommit == nil, comment.side != "old", !comment.quote.isEmpty
            else { continue }
            if files[comment.file] == nil {
                let text = Log.store.attempt("reading \(comment.file) for its comments") {
                    try FileService(remotes: scm.remotes).read(folder + "/" + comment.file).text
                }
                files[comment.file] = text.map { $0.components(separatedBy: "\n") } ?? []
            }
            let quote = comment.quote.components(separatedBy: "\n")
            guard let start = place(of: quote, near: comment.startLine, in: files[comment.file] ?? []),
                start != comment.startLine
            else { continue }
            // Only the lines are written, because writing a copy read before would put back a state changed
            // meanwhile (sent, resolved).
            let end = start + quote.count - 1
            comment =
                try scm.store.update(DiffComment.self, comment.id) {
                    $0.startLine = start
                    $0.endLine = end
                } ?? comment
        }
        return out
    }

    /// Returns where the lines of `quote` start in `lines` (1-based). That is `near` when they are there, or else the
    /// nearest place they are. Returns nil when they are nowhere.
    static func place(of quote: [String], near: Int, in lines: [String]) -> Int? {
        guard !quote.isEmpty, lines.count >= quote.count else { return nil }
        let at = { (start: Int) in Array(lines[(start - 1)..<(start - 1 + quote.count)]) == quote }
        if near >= 1, near + quote.count - 1 <= lines.count, at(near) { return near }
        return (1...(lines.count - quote.count + 1)).filter(at).min { abs($0 - near) < abs($1 - near) }
    }
}
extension CommentSetState: Handled {
    func handle(_ scm: SourceControl) throws -> Done {
        guard let next = DiffComment.State(rawValue: state) else {
            let states = DiffComment.State.allCases.map(\.rawValue).joined(separator: ", ")
            throw RPCError.invalidParams("A comment is \(states), not \(state).")
        }
        // Only the state is written, in one write, because a copy read first would put back lines that a move wrote
        // meanwhile.
        guard try scm.store.update(DiffComment.self, id, { $0.state = next }) != nil else {
            throw RPCError.invalidParams("That comment is gone: it was deleted, or its workspace removed.")
        }
        return Done()
    }
}
/// Sends the open comments (all of them, or those in `only`) as one message into the agent's terminal.
extension CommentSend: Handled {
    static let agents = AgentAccess.acts
    /// The send types the message and Enter, so an agent may send only to itself and the sessions it started. It is a
    /// send (`SessionSend`, whose handler it calls past `allow`), so it is refused while the session asks a question.
    var fence: Fence { Fence(actsOn: session, typesInto: session) }
    func handle(_ scm: SourceControl) throws -> Int {
        let workspace = try scm.store.worktree(named: id)
        // Comments go into an agent only, because a shell would run each line of the message (another agent's
        // findings, quoted code). The check reads the session's record, not only a running session, because a paused
        // agent is an agent too, and the send wakes it.
        guard
            try (scm.live[session]?.snapshot ?? scm.store.session(session))?.isAgent == true
        else {
            throw RPCError.invalidParams("Comments go to an agent, not to a terminal.")
        }
        // Moves the comments to where their lines are now, so they are sent with the current line numbers.
        _ = try CommentPlaces.follow(try scm.store.comments(worktree: workspace.id), in: workspace.path, scm)
        let wanted = only.map(Set.init)
        // The comments are read and marked sent in one write. So a second send at the same moment (a double click, or
        // the CLI beside the window) finds none of them open and doesn't type them in again. They are put back if the
        // send fails.
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
            try scm.send(SessionSend(id: session, text: Self.message(branch: workspace.branch, comments: open)))
        } catch {
            // Marks the comments open again, but only those still marked sent: not one whose state changed meanwhile,
            // nor one gone with its workspace. The caller is told the send's error, whatever this does.
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

    /// Writes the message, with the file, lines, quoted code and remark for each comment. The branch's name is framed:
    /// a pull request's branch was named by whoever pushed it.
    static func message(branch: String, comments: [DiffComment]) -> String {
        var body =
            "Review comments on the branch below. Please address each one:\n"
            + Untrusted.frame(branch, what: "branch name") + "\n"
        for (index, comment) in comments.enumerated() {
            let range =
                comment.startLine == comment.endLine
                ? "\(comment.startLine)" : "\(comment.startLine)-\(comment.endLine)"
            let removed = comment.side == "old" ? " (removed lines, numbered as in the file before this change)" : ""
            let past = comment.onCommit.map { " (in commit \($0.prefix(12)), not the current changes)" } ?? ""
            let head = "\(comment.file):\(range)\(removed)\(past)\n"
            let quote = comment.quote.split(separator: "\n", omittingEmptySubsequences: false).map { "   > \($0)" }
                .joined(separator: "\n")
            let entry: String
            if let author = comment.author {
                // Another agent's finding is data to weigh, not the user's word, because it may quote what a pull
                // request said. The whole entry is framed, its place and quote too, because that agent wrote all of it.
                entry = Untrusted.frame(head + quote + "\n   " + comment.text, what: "\(author)'s finding")
            } else {
                // The user's remark is the user's own words; the lines it quotes are the file's, written by whoever
                // changed them last.
                let quoted = comment.quote.isEmpty ? "" : Untrusted.frame(quote, what: "quoted lines") + "\n"
                entry = head + quoted + "   " + comment.text
            }
            body += "\n\(index + 1). " + entry + "\n"
        }
        return body
    }
}

extension Methods {
    static let commentMethods: [any Answered.Type] = [
        CommentAdd.self, CommentList.self, CommentSetState.self, CommentSend.self
    ]
}
