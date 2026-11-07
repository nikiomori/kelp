import Core
import Foundation

extension Main {
    /// `diff`, `commit`, `merge`, `push`, `comment …` in the current workspace.
    static func git(_ cmd: String, _ sub: String?, _ c: RPCClient) async throws {
        switch (cmd, sub) {
        case ("diff", _):
            for f in try await c.call(GitDiff(id: try await currentWorktreeID(c), source: flag("--source") ?? "all")) {
                print(
                    "\(f.path)  "
                        + (f.tooLarge == true ? "(too large to count here)" : "+\(f.additions) -\(f.deletions)"))
            }
        case ("commit", _):
            show(
                try await c.call(
                    GitCommit(
                        id: try await currentWorktreeID(c),
                        message: ([sub].compactMap { $0 } + args).joined(separator: " "), all: true)))
        case ("merge", _): show(try await c.call(GitMerge(id: try await currentWorktreeID(c))))
        case ("push", _): show(try await c.call(GitPush(id: try await currentWorktreeID(c))))
        case ("comment", "add"):
            guard args.count >= 3 else { fail("comment add <file> <line[-line]> <text>") }
            let range = args[1].split(separator: "-").compactMap { Int($0) }
            let id = try await currentWorktreeID(c), text = args.dropFirst(2).joined(separator: " ")
            show(
                try await c.call(
                    CommentAdd(
                        id: id, file: args[0], start: range.first ?? 1, end: range.last ?? 1, text: text,
                        session: ProcessInfo.processInfo.environment["KELP_SESSION"])))
        case ("comment", "send"):
            show(
                try await c.call(
                    CommentSend(
                        id: try await currentWorktreeID(c),
                        session: try await resolve(c, args.first ?? "", "session.list"))))
        default: print(usage)
        }
    }

    /// `github …`, `linear …`.
    static func forge(_ cmd: String, _ sub: String?, _ c: RPCClient) async throws {
        switch (cmd, sub) {
        case ("github", "prs"):
            for x in try await c.call(GitHubPRs(repoId: try await currentRepoID(c), filter: flag("--filter"))) {
                print("#\(x.number)  \(x.title)  \(x.url)")
            }
        case ("github", "issues"):
            for x in try await c.call(GitHubIssues(repoId: try await currentRepoID(c), filter: flag("--filter"))) {
                print("#\(x.number)  \(x.title)  \(x.url)")
            }
        case ("github", "checks"):
            let worktree = try await currentWorktree(c)
            let pr = args.first.flatMap(Int.init) ?? worktree.prNumber ?? 0
            for x in try await c.call(GitHubChecks(worktreeId: worktree.id, pr: pr)) {
                print("\(x.bucket)\t\(x.name)\t\(x.link)")
            }
        case ("github", "pr-create"):
            let wid = try await currentWorktreeID(c)
            show(
                .string(
                    try await c.call(
                        GitHubPRCreate(worktreeId: wid, title: flag("--title"), draft: has("--draft") ? true : nil)
                    ).url))
        case ("github", "pr-merge"):
            let wid = try await currentWorktreeID(c)
            show(try .from(try await c.call(GitHubPRMerge(worktreeId: wid, method: flag("--method") ?? "squash"))))
        case ("github", "issue"), ("linear", "start"):   // kelp github issue 123 | kelp linear start ENG-123
            let repo = try await currentRepoID(c)
            guard let ref = args.first else { fail("issue number / identifier required") }
            var params: [String: JSONValue] = ["repoId": .string(repo), "agent": .string(flag("--agent") ?? "claude")]
            if cmd == "github" {
                let number = Int(ref.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) ?? 0
                let open = try await c.call(GitHubIssues(repoId: repo))
                guard let issue = open.first(where: { $0.number == number }) else {
                    fail("issue #\(number) not found among open issues")
                }
                params["ref"] = .string("#\(number)")
                params["title"] = .string(issue.title)
                params["body"] = .string(issue.body)
                params["url"] = .string(issue.url)
            } else {
                let mine = try await c.call(LinearIssues())
                guard let issue = mine.first(where: { $0.identifier.lowercased() == ref.lowercased() }) else {
                    fail("\(ref) not found in your Linear issues")
                }
                params["ref"] = .string(issue.identifier)
                params["title"] = .string(issue.title)
                params["body"] = .string(issue.description ?? "")
                params["url"] = .string(issue.url)
                params["linearId"] = .string(issue.id)
            }
            if has("--send") { params["draft"] = false }
            let task = try await c.call(try JSONValue.object(params).decode(TaskFromIssue.self))
            print("\(task.worktree.branch)  \(task.worktree.path)")
            if !has("--send") {
                print("The issue's text is typed into the agent, not sent: look it over in Kelp and press Return.")
            }
            if task.setupNeedsTrust {
                print("Its setup didn't run: open the project in Kelp to look at its commands and trust them.")
            }
        case ("linear", "tasks"):
            for x in try await c.call(LinearIssues()) { print("\(x.identifier)  [\(x.state.name)]  \(x.title)") }
        case ("linear", "login"):
            guard let key = args.first else { fail("linear login <api-key>") }
            show(try .from(try await c.call(LinearSetKey(key: key))))
        default: print(usage)
        }
    }
}
