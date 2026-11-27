import Core
import Foundation

extension Main {
    /// Runs `diff`, `commit`, `merge`, `push` and `comment …` in the current workspace.
    static func git(_ cmd: String, _ sub: String?, _ client: RPCClient) async throws {
        switch (cmd, sub) {
        case ("diff", _):
            let named = flag("--source") ?? "all"
            guard let source = GitDiff.Source(rawValue: named) else {
                let known = GitDiff.Source.allCases.map(\.rawValue).joined(separator: ", ")
                throw RPCError.invalidParams("no diff source “\(named)”: one of \(known)")
            }
            for file in try await client.call(GitDiff(id: try await currentWorktreeID(client), source: source)) {
                print(
                    "\(file.path)  "
                        + (file.tooLarge == true
                            ? "(too large to count here)" : "+\(file.additions) -\(file.deletions)"))
            }
        // Asking how a command works never runs it. "kelp commit --help" once committed everything with the message
        // "--help".
        case ("commit", _) where has("--help") || has("-h"):
            print(
                """
                kelp commit <message>                         commit every change in this workspace (the user's)
                kelp commit add <file>… -m <subject> [-m <body>]   propose one commit of these files, whole; the user
                                                                 looks it over in Kelp's Source Control and makes it
                """)
        case ("commit", "add"):
            let (files, message) = planned(args)
            guard !files.isEmpty, !message.isEmpty else { fail("commit add <file>… -m <subject> [-m <body>]") }
            let count = try await client.call(
                CommitPlanAdd(
                    worktreeId: try await currentWorktreeID(client), files: files, message: message,
                    session: ProcessInfo.processInfo.environment["KELP_SESSION"]))
            print("Commit \(count) proposed: the user looks it over in Kelp's Source Control and makes it.")
        case ("commit", _):
            show(
                try await client.call(
                    GitCommit(
                        id: try await currentWorktreeID(client),
                        message: ([sub].compactMap { $0 } + args).joined(separator: " "), all: true)))
        case ("merge", _): show(try await client.call(GitMerge(id: try await currentWorktreeID(client))))
        case ("push", _): show(try await client.call(GitPush(id: try await currentWorktreeID(client))))
        case ("comment", "add"):
            guard args.count >= 3 else { fail("comment add <file> <line[-line]> <text>") }
            let range = args[1].split(separator: "-").compactMap { Int($0) }
            let id = try await currentWorktreeID(client), text = args.dropFirst(2).joined(separator: " ")
            show(
                try await client.call(
                    CommentAdd(
                        id: id, file: args[0], start: range.first ?? 1, end: range.last ?? 1, text: text,
                        session: ProcessInfo.processInfo.environment["KELP_SESSION"])))
        case ("comment", "send"):
            show(
                try await client.call(
                    CommentSend(
                        id: try await currentWorktreeID(client),
                        session: try await session(client, args.first ?? ""))))
        default: print(usage)
        }
    }

    /// Parses `kelp commit add <file>… -m <subject> [-m <body>]` into the files, and the message with its paragraphs
    /// joined the way git joins them.
    static func planned(_ args: [String]) -> (files: [String], message: String) {
        var files: [String] = [], parts: [String] = []
        var it = args.makeIterator()
        while let argument = it.next() {
            if argument == "-m" {
                if let part = it.next() { parts.append(part) }
            } else {
                files.append(argument)
            }
        }
        return (files, parts.joined(separator: "\n\n"))
    }

    /// Runs `github …` and `linear …`.
    static func forge(_ cmd: String, _ sub: String?, _ client: RPCClient) async throws {
        switch (cmd, sub) {
        case ("github", "prs"):
            let filter = flag("--filter").map { asked -> GitHub.PRFilter in
                guard let filter = GitHub.PRFilter(rawValue: asked) else {
                    fail("kelp github prs --filter mine|review|closed")
                }
                return filter
            }
            for pr in try await client.call(GitHubPRs(repoId: try await currentRepoID(client), filter: filter)) {
                print("#\(pr.number)  \(pr.title)  \(pr.url)")
            }
        case ("github", "issues"):
            for item in try await client.call(
                GitHubIssues(repoId: try await currentRepoID(client), filter: flag("--filter")))
            {
                print("#\(item.number)  \(item.title)  \(item.url)")
            }
        case ("github", "checks"):
            let worktree = try await currentWorktree(client)
            let pr = args.first.flatMap(Int.init) ?? worktree.prNumber ?? 0
            for check in try await client.call(GitHubChecks(worktreeId: worktree.id, pr: pr)) {
                print("\(check.bucket)\t\(check.name)\t\(check.link)")
            }
        case ("github", "pr-create"):
            let wid = try await currentWorktreeID(client)
            show(
                .string(
                    try await client.call(
                        GitHubPRCreate(worktreeId: wid, title: flag("--title"), draft: has("--draft") ? true : nil)
                    ).url))
        case ("github", "pr-merge"):
            let wid = try await currentWorktreeID(client)
            show(try .from(try await client.call(GitHubPRMerge(worktreeId: wid, method: flag("--method") ?? "squash"))))
        case ("github", "issue"), ("linear", "start"):   // kelp github issue 123 | kelp linear start ENG-123
            let repo = try await currentRepoID(client)
            guard let ref = args.first else { fail("issue number / identifier required") }
            let agent = flag("--agent") ?? Session.claudeAgent, draft: Bool? = has("--send") ? false : nil
            let request: TaskFromIssue
            if cmd == "github" {
                let number = Int(ref.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) ?? 0
                let open = try await client.call(GitHubIssues(repoId: repo))
                guard let issue = open.first(where: { $0.number == number }) else {
                    fail("issue #\(number) not found among open issues")
                }
                request = TaskFromIssue(
                    repoId: repo, ref: "#\(number)", title: issue.title, body: issue.body, url: issue.url, agent: agent,
                    draft: draft)
            } else {
                let mine = try await client.call(LinearIssues())
                guard let issue = mine.first(where: { $0.identifier.lowercased() == ref.lowercased() }) else {
                    fail("\(ref) not found in your Linear issues")
                }
                request = TaskFromIssue(
                    repoId: repo, ref: issue.identifier, title: issue.title, body: issue.description ?? "",
                    url: issue.url,
                    linearId: issue.id, agent: agent, draft: draft)
            }
            let task = try await client.call(request)
            print("\(task.worktree.branch)  \(task.worktree.path)")
            if !has("--send") {
                print("The issue's text is typed into the agent, not sent: look it over in Kelp and press Return.")
            }
            if task.setupNeedsTrust {
                print("Its setup didn't run: open the project in Kelp to look at its commands and trust them.")
            }
        case ("linear", "tasks"):
            for x in try await client.call(LinearIssues()) { print("\(x.identifier)  [\(x.state.name)]  \(x.title)") }
        case ("linear", "login"):
            guard let key = args.first else { fail("linear login <api-key>") }
            show(try .from(try await client.call(LinearSetKey(key: key))))
        default: print(usage)
        }
    }
}
