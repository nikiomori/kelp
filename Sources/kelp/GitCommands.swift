import Foundation
import Core

extension Main {
    /// `diff`, `commit`, `merge`, `push`, `comment …` in the current workspace.
    static func git(_ cmd: String, _ sub: String?, _ c: RPCClient) async throws {
        switch (cmd, sub) {
        case ("diff", _):
            for f in try await c.call(GitDiff(id: try await currentWorktreeID(c), source: flag("--source") ?? "all")) {
                print("\(f.path)  " + (f.tooLarge == true ? "(too large to count here)" : "+\(f.additions) -\(f.deletions)"))
            }
        case ("commit", _):
            show(try await c.call(GitCommit(id: try await currentWorktreeID(c), message: ([sub].compactMap { $0 } + args).joined(separator: " "), all: true)))
        case ("merge", _): show(try await c.call(GitMerge(id: try await currentWorktreeID(c))))
        case ("push", _): show(try await c.call(GitPush(id: try await currentWorktreeID(c))))
        case ("comment", "add"):
            guard args.count >= 3 else { fail("comment add <file> <line[-line]> <text>") }
            let range = args[1].split(separator: "-").compactMap { Int($0) }
            let id = try await currentWorktreeID(c), text = args.dropFirst(2).joined(separator: " ")
            show(try await c.call(CommentAdd(id: id, file: args[0], start: range.first ?? 1, end: range.last ?? 1, text: text)))
        case ("comment", "send"):
            show(try await c.call(CommentSend(id: try await currentWorktreeID(c), session: try await resolve(c, args.first ?? "", "session.list"))))
        default: print(usage)
        }
    }

    /// `github …`, `linear …`.
    static func forge(_ cmd: String, _ sub: String?, _ c: RPCClient) async throws {
        switch (cmd, sub) {
        case ("github", "prs"):
            for x in try await c.call(GitHubPRs(repoId: try await currentRepoID(c), filter: flag("--filter"))) { print("#\(x.number)  \(x.title)  \(x.url)") }
        case ("github", "issues"):
            for x in try await c.call(GitHubIssues(repoId: try await currentRepoID(c), filter: flag("--filter"))) {
                print("#\(x.number)  \(x.title)  \(x.url)")
            }
        case ("github", "checks"):
            let w = try await currentWorktree(c)
            let pr = args.first.flatMap(Int.init) ?? w.prNumber ?? 0
            for x in try await c.call(GitHubChecks(worktreeId: w.id, pr: pr)) { print("\(x.bucket)\t\(x.name)\t\(x.link)") }
        case ("github", "pr-create"):
            let wid = try await currentWorktreeID(c)
            show(.string(try await c.call(GitHubPRCreate(worktreeId: wid, title: flag("--title"), draft: has("--draft") ? true : nil)).url))
        case ("github", "pr-merge"):
            let wid = try await currentWorktreeID(c)
            show(try .from(try await c.call(GitHubPRMerge(worktreeId: wid, method: flag("--method") ?? "squash"))))
        case ("github", "issue"), ("linear", "start"):   // kelp github issue 123 | kelp linear start ENG-123
            let repo = try await currentRepoID(c)
            guard let ref = args.first else { fail("issue number / identifier required") }
            var p: [String: JSONValue] = ["repoId": .string(repo), "agent": .string(flag("--agent") ?? "claude")]
            if cmd == "github" {
                let n = Int(ref.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) ?? 0
                let open = try await c.call(GitHubIssues(repoId: repo))
                guard let i = open.first(where: { $0.number == n }) else { fail("issue #\(n) not found among open issues") }
                p["ref"] = .string("#\(n)"); p["title"] = .string(i.title); p["body"] = .string(i.body); p["url"] = .string(i.url)
            } else {
                let mine = try await c.call(LinearIssues())
                guard let i = mine.first(where: { $0.identifier.lowercased() == ref.lowercased() }) else { fail("\(ref) not found in your Linear issues") }
                p["ref"] = .string(i.identifier); p["title"] = .string(i.title); p["body"] = .string(i.description ?? ""); p["url"] = .string(i.url)
                p["linearId"] = .string(i.id)
            }
            if has("--send") { p["draft"] = false }
            let r = try await c.call(try JSONValue.object(p).decode(TaskFromIssue.self))
            print("\(r.worktree.branch)  \(r.worktree.path)")
            if !has("--send") { print("The issue's text is typed into the agent, not sent: look it over in Kelp and press Return.") }
            if r.setupNeedsTrust { print("Its .kelp.yaml setup didn't run: open the project in Kelp to look at it and trust it.") }
        case ("linear", "tasks"):
            for x in try await c.call(LinearIssues()) { print("\(x.identifier)  [\(x.state.name)]  \(x.title)") }
        case ("linear", "login"):
            guard let k = args.first else { fail("linear login <api-key>") }
            show(try .from(try await c.call(LinearSetKey(key: k))))
        default: print(usage)
        }
    }
}
