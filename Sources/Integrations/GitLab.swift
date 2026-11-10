import Core
import Foundation
import GitKit

/// GitLab through the `glab` CLI and its login (`glab auth login`), the way GitHub goes through `gh`: merge requests,
/// issues and pipelines in GitHub's shapes, so the panels show either. Self-managed hosts work as glab knows them.
public enum GitLab {
    /// `KELP_GLAB` names another program (tests use a stand-in), like `KELP_GH` for gh.
    static var glabPath: String? {
        ProcessInfo.processInfo.environment["KELP_GLAB"] ?? LoginPath.find("glab")
    }

    /// For Settings: is glab installed, and who it's signed in as ("ada on gitlab.com"; nil: not signed in anywhere).
    /// `glab auth status` covers self-managed hosts too, where `glab api user` would only ask gitlab.com.
    public static func account() -> (installed: Bool, user: String?) {
        guard let exe = glabPath else { return (false, nil) }
        let out = try? Subprocess.run(
            [exe, "auth", "status"], cwd: NSHomeDirectory(), env: ProcessInfo.processInfo.environment, timeLimit: 20)
        return (true, out.flatMap { signedIn(String(decoding: $0.stdout + $0.stderr, as: UTF8.self)) })
    }

    /// "✓ Logged in to gitlab.com as ada (…/config.yml)" → "ada on gitlab.com", each host's.
    static func signedIn(_ status: String) -> String? {
        let who = status.matches(of: /Logged in to (\S+) as (\S+)/).map { "\($0.2) on \($0.1)" }
        return who.isEmpty ? nil : who.joined(separator: ", ")
    }

    /// `glab api` with `:id` standing for this project (glab fills it in from the remote).
    static func api(_ path: String, cwd: String, method: String = "GET", fields: [(String, String)] = []) throws -> Data
    {
        guard let exe = glabPath else {
            throw ForgeError.notInstalled("glab", [path])
        }
        // raw: a title is text, never read as a number or a file
        let rawFields = fields.flatMap { ["--raw-field", "\($0.0)=\($0.1)"] }
        let args = ["api", "-X", method, path] + rawFields
        do { return try Subprocess.output([exe] + args, cwd: cwd, env: Git.toolEnv) } catch let error as ProgramError {
            throw ForgeError(tool: "glab", args: args, status: error.status, stderr: error.stderr)
        }
    }

    /// A value for a query string: everything but unreserved characters escaped, so "fix+x" or "a&b=c" stay one value
    /// (`.urlQueryAllowed` leaves + & = as they are, and "+" reads as a space).
    static func queryValue(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(
                charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? value
    }

    struct RawMR: Decodable {
        struct User: Decodable { var username: String }
        struct Pipeline: Decodable { var status: String }
        var iid: Int, title: String, web_url: String, author: User, source_branch: String, state: String
        var draft: Bool?, work_in_progress: Bool?, head_pipeline: Pipeline?
    }

    static func pr(_ request: RawMR) -> GitHub.PullRequest {
        var checks = GitHub.PullRequest.Checks()
        switch request.head_pipeline?.status {
        case "success"?: checks.passed = 1
        case "failed"?: checks.failed = 1
        case "running"?, "pending"?, "created"?, "preparing"?, "waiting_for_resource"?: checks.pending = 1
        default: break
        }
        let state =
            ["opened": "OPEN", "merged": "MERGED", "closed": "CLOSED"][request.state] ?? request.state.uppercased()
        return GitHub.PullRequest(
            number: request.iid, title: request.title, url: request.web_url, author: request.author.username,
            headRefName: request.source_branch, isDraft: request.draft ?? request.work_in_progress ?? false,
            state: state, reviewDecision: nil, checks: checks)
    }

    public static func mergeRequests(cwd: String, mine: Bool) throws -> [GitHub.PullRequest] {
        try JSONDecoder().decode(
            [RawMR].self,
            from: api(
                "projects/:id/merge_requests?state=opened&per_page=50" + (mine ? "&scope=created_by_me" : ""),
                cwd: cwd)
        ).map(pr)
    }

    /// The newest MR from `branch`, with its pipeline's state.
    public static func mergeRequest(cwd: String, branch: String) throws -> GitHub.PullRequest? {
        let source = queryValue(branch)
        guard
            let request = try JSONDecoder().decode(
                [RawMR].self,
                from: api(
                    "projects/:id/merge_requests?source_branch=\(source)&state=all&per_page=1&order_by=updated_at",
                    cwd: cwd)
            )
            .first
        else { return nil }
        return pr(
            (try? JSONDecoder().decode(RawMR.self, from: api("projects/:id/merge_requests/\(request.iid)", cwd: cwd)))
                ?? request)
    }

    /// Opens a merge request from the branch checked out now (pushed already) into `base`; returns its page's URL.
    public static func createMR(cwd: String, title: String, body: String, base: String, draft: Bool) throws -> String {
        let branch = try Git.currentBranch(cwd, remotes: .none)
        let request = try JSONDecoder().decode(
            RawMR.self,
            from: api(
                "projects/:id/merge_requests", cwd: cwd, method: "POST",
                fields: [
                    ("source_branch", branch), ("target_branch", base), ("title", draft ? "Draft: " + title : title),
                    ("description", body)
                ]))
        return request.web_url
    }

    /// Merges it now, squashed unless asked otherwise.
    public static func mergeMR(cwd: String, number: Int, squash: Bool) throws {
        _ = try api(
            "projects/:id/merge_requests/\(number)/merge", cwd: cwd, method: "PUT",
            fields: [("squash", squash ? "true" : "false")])
    }

    struct RawIssue: Decodable {
        struct User: Decodable { var username: String }
        var iid: Int, title: String, description: String?, web_url: String, labels: [String], assignees: [User],
            state: String
    }

    /// The avatar of the account behind a commit author's email on this repo's GitLab, 64 px. A Gravatar the instance
    /// falls back to is left out: the email's hash would go to a third party. nil: no account has it.
    public static func avatarURL(email: String, cwd: String) throws -> URL? {
        struct Raw: Decodable { var avatar_url: String? }
        let raw = try JSONDecoder().decode(Raw.self, from: api("avatar?email=\(queryValue(email))&size=64", cwd: cwd))
        guard let url = raw.avatar_url.flatMap(URL.init(string:)), url.host?.contains("gravatar") != true else {
            return nil
        }
        return url
    }

    public static func issues(cwd: String, mine: Bool) throws -> [GitHub.Issue] {
        try JSONDecoder().decode(
            [RawIssue].self,
            from: api(
                "projects/:id/issues?state=opened&per_page=50" + (mine ? "&scope=assigned_to_me" : ""),
                cwd: cwd)
        ).map {
            GitHub.Issue(
                number: $0.iid, title: $0.title, body: $0.description ?? "", url: $0.web_url, labels: $0.labels,
                assignees: $0.assignees.map(\.username), state: $0.state == "opened" ? "OPEN" : $0.state.uppercased())
        }
    }
}
