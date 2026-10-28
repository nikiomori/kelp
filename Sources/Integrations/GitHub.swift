import Foundation
import Core
import GitKit

public struct GitHubError: Error, CustomStringConvertible, Sendable {
    public var args: [String]; public var status: Int32; public var stderr: String
    /// What the user can act on, not the command line (`args` is there for logs).
    public var description: String {
        let e = stderr.lowercased()
        if e.contains("not found (brew install gh)") { return "Install GitHub CLI to see pull requests and issues: brew install gh" }
        if e.contains("no git remotes") || e.contains("known github host") { return GitHub.noRemote }
        if e.contains("gh auth login") || e.contains("not logged in") { return "GitHub CLI isn't signed in — run gh auth login." }
        return stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? "gh failed (\(status))"
    }
}

/// GitHub via the `gh` CLI; auth is whatever `gh auth` has. Every call takes the repo checkout `cwd`
/// so gh resolves owner/repo from its remotes. Blocking — call off the main thread. Its values are Core's.
extension GitHub {
    public enum PRFilter: Sendable { case open, mine, reviewRequested }
    public enum MergeMethod: String, Sendable { case squash, merge, rebase }

    static let prFields = "number,title,url,author,headRefName,isDraft,state,reviewDecision,statusCheckRollup"

    /// Where the user's shell finds it (MacPorts, nix, mise… too), not only in the daemon's own PATH.
    /// `KELP_GH` names another program (tests use a stand-in that answers with canned JSON), like `KELP_SSH`.
    /// Looked up each time (a scan of PATH's folders): installed while Kelp runs, it works on the next try.
    static var ghPath: String? { ProcessInfo.processInfo.environment["KELP_GH"] ?? (try? LoginPath.resolve("gh")) }

    @discardableResult
    static func gh(_ args: [String], cwd: String) throws -> Data {
        guard let exe = ghPath else { throw GitHubError(args: args, status: -1, stderr: "gh CLI not found (brew install gh)") }
        do { return Data(try Git.run(args, cwd: cwd, executable: exe).utf8) }
        catch let e as GitError { throw GitHubError(args: args, status: e.status, stderr: e.stderr) }
    }

    /// For Settings: is gh installed, and who is signed in (nil: not signed in, or no network to ask).
    public static func account() -> (installed: Bool, user: String?) {
        guard let exe = ghPath else { return (false, nil) }
        let login = (try? Git.run(["api", "user", "--jq", ".login"], cwd: NSHomeDirectory(), executable: exe))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (true, login?.isEmpty == false ? login : nil)
    }

    // MARK: Commands

    /// The avatar of the account behind a commit author's email, 64 px. A noreply address names its account, so that
    /// one needs no call; any other is looked up among this repo's commits (GitHub ties an email to an account only
    /// through them). nil: no account has it.
    public static func avatarURL(email: String, cwd: String) throws -> URL? {
        if let u = noreplyAvatar(email) { return u }
        let q = "repos/{owner}/{repo}/commits?author=\(GitLab.queryValue(email))&per_page=1"
        let s = String(decoding: try gh(["api", q, "--jq", ".[0].author.avatar_url // empty"], cwd: cwd), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : URL(string: s + (s.contains("?") ? "&" : "?") + "s=64")
    }

    /// "123+ada@users.noreply.github.com" is account 123; the older "ada@users.noreply.github.com" is ada's.
    public static func noreplyAvatar(_ email: String) -> URL? {
        if let m = email.lowercased().wholeMatch(of: /(\d+)\+[^@]+@users\.noreply\.github\.com/) {
            return URL(string: "https://avatars.githubusercontent.com/u/\(m.1)?s=64")
        }
        if let m = email.lowercased().wholeMatch(of: /([a-z0-9-]+)@users\.noreply\.github\.com/) { return URL(string: "https://github.com/\(m.1).png?size=64") }
        return nil
    }

    public static func pullRequests(cwd: String, filter: PRFilter = .open) throws -> [PullRequest] {
        let extra: [String] = switch filter {
        case .open: []
        case .mine: ["--author", "@me"]
        case .reviewRequested: ["--search", "review-requested:@me"]
        }
        return try parsePullRequests(gh(["pr", "list", "-L", "100", "--json", prFields] + extra, cwd: cwd))
    }

    /// The newest PR whose head is `branch` (open, merged or closed), or nil.
    public static func pullRequest(cwd: String, branch: String) throws -> PullRequest? {
        try parsePullRequests(gh(["pr", "list", "--head", branch, "--state", "all", "-L", "1", "--json", prFields], cwd: cwd)).first
    }

    public static func issues(cwd: String, mine: Bool) throws -> [Issue] {
        let extra = mine ? ["--assignee", "@me"] : []
        return try parseIssues(gh(["issue", "list", "-L", "100", "--json", "number,title,body,url,labels,assignees,state"] + extra, cwd: cwd))
    }

    public static func checks(cwd: String, pr: Int) throws -> [Check] {
        do { return try parseChecks(gh(["pr", "checks", String(pr), "--json", "name,state,link,bucket,workflow"], cwd: cwd)) }
        catch let e as GitHubError where e.stderr.contains("no checks reported") { return [] }
    }

    /// Failed-step logs of a workflow run, last ~12 KB.
    public static func failedLog(cwd: String, runId: Int) throws -> String {
        tail(String(decoding: try gh(["run", "view", String(runId), "--log-failed"], cwd: cwd), as: UTF8.self))
    }

    /// Inline review comments plus non-empty top-level review bodies.
    public static func reviewComments(cwd: String, pr: Int) throws -> [ReviewComment] {
        let inline = try parseReviewComments(gh(["api", "--paginate", "--slurp", "repos/{owner}/{repo}/pulls/\(pr)/comments"], cwd: cwd))
        return try parseReviews(gh(["pr", "view", String(pr), "--json", "reviews"], cwd: cwd)) + inline
    }

    /// Returns the new PR's URL. The current branch must already be pushed.
    public static func createPR(cwd: String, title: String, body: String, base: String, draft: Bool = false) throws -> String {
        let out = try gh(["pr", "create", "--title", title, "--body", body, "--base", base] + (draft ? ["--draft"] : []), cwd: cwd)
        return String(decoding: out, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
    }

    public static func mergePR(cwd: String, number: Int, method: MergeMethod) throws {
        try gh(["pr", "merge", String(number), "--\(method.rawValue)"], cwd: cwd)
    }

    public static func projects(cwd: String) throws -> [Project] {
        let owner = try parseOwner(gh(["repo", "view", "--json", "owner"], cwd: cwd))
        return try parseProjects(gh(["project", "list", "--owner", owner, "--format", "json"], cwd: cwd))
    }

    public static func projectItems(owner: String, number: Int) throws -> [ProjectItem] {
        try parseProjectItems(gh(["project", "item-list", String(number), "--owner", owner, "--format", "json", "-L", "200"], cwd: NSHomeDirectory()))
    }

    // MARK: Parsing (pure)

    private struct Login: Decodable { var login: String }
    private struct Name: Decodable { var name: String }
    private struct RawRollup: Decodable {
        var name: String?, context: String?, workflowName: String?, startedAt: String?
        var status: String?, conclusion: String?, state: String?
    }
    private struct RawPR: Decodable {
        var number: Int, title: String, url: String, author: Login, headRefName: String
        var isDraft: Bool, state: String, reviewDecision: String?, statusCheckRollup: [RawRollup]?
    }

    public static func parsePullRequests(_ data: Data) throws -> [PullRequest] {
        try JSONDecoder().decode([RawPR].self, from: data).map {
            PullRequest(number: $0.number, title: $0.title, url: $0.url, author: $0.author.login, headRefName: $0.headRefName,
                        isDraft: $0.isDraft, state: $0.state, reviewDecision: $0.reviewDecision?.isEmpty == false ? $0.reviewDecision : nil,
                        checks: summarize($0.statusCheckRollup ?? []))
        }
    }

    /// The rollup keeps check runs from superseded workflow runs; count only the latest per workflow/name.
    private static func summarize(_ rollup: [RawRollup]) -> PullRequest.Checks {
        var latest: [String: RawRollup] = [:]
        for r in rollup {
            let key = "\(r.workflowName ?? "")/\(r.name ?? r.context ?? "")"
            if let old = latest[key], (old.startedAt ?? "") > (r.startedAt ?? "") { continue }
            latest[key] = r
        }
        var c = PullRequest.Checks()
        for r in latest.values {
            // CheckRun has status+conclusion; StatusContext has only state.
            switch r.status.map({ $0 == "COMPLETED" ? r.conclusion ?? "" : "PENDING" }) ?? r.state ?? "" {
            case "SUCCESS": c.passed += 1
            case "PENDING", "EXPECTED": c.pending += 1
            case "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": c.failed += 1
            default: break // NEUTRAL, SKIPPED, STALE
            }
        }
        return c
    }

    private struct RawIssue: Decodable {
        var number: Int, title: String, body: String?, url: String, labels: [Name], assignees: [Login], state: String
    }

    public static func parseIssues(_ data: Data) throws -> [Issue] {
        try JSONDecoder().decode([RawIssue].self, from: data).map {
            Issue(number: $0.number, title: $0.title, body: $0.body ?? "", url: $0.url,
                  labels: $0.labels.map(\.name), assignees: $0.assignees.map(\.login), state: $0.state)
        }
    }

    public static func parseChecks(_ data: Data) throws -> [Check] {
        try JSONDecoder().decode([Check].self, from: data).map { var c = $0; c.runId = runId(fromLink: c.link); return c }
    }

    /// `https://github.com/o/r/actions/runs/123/job/456` -> 123
    public static func runId(fromLink link: String) -> Int? {
        (link.firstMatch(of: #/actions/runs/(\d+)/#)?.1).flatMap { Int($0) }
    }

    private struct RawComment: Decodable {
        var path: String, line: Int?, original_line: Int?, body: String, user: Login, html_url: String
    }

    /// Input is `gh api --paginate --slurp` output: an array of pages.
    public static func parseReviewComments(_ data: Data) throws -> [ReviewComment] {
        try JSONDecoder().decode([[RawComment]].self, from: data).joined().map {
            ReviewComment(path: $0.path, line: $0.line ?? $0.original_line, body: $0.body, author: $0.user.login, url: $0.html_url)
        }
    }

    private struct RawReviews: Decodable {
        struct Review: Decodable { var author: Login?; var body: String }
        var reviews: [Review]
    }

    public static func parseReviews(_ data: Data) throws -> [ReviewComment] {
        try JSONDecoder().decode(RawReviews.self, from: data).reviews.filter { !$0.body.isEmpty }.map {
            ReviewComment(path: nil, line: nil, body: $0.body, author: $0.author?.login ?? "ghost", url: nil)
        }
    }

    private struct RawOwner: Decodable { var owner: Login }
    public static func parseOwner(_ data: Data) throws -> String { try JSONDecoder().decode(RawOwner.self, from: data).owner.login }

    private struct RawProjects: Decodable { var projects: [Project] }
    public static func parseProjects(_ data: Data) throws -> [Project] { try JSONDecoder().decode(RawProjects.self, from: data).projects }

    private struct RawItems: Decodable {
        struct Content: Decodable { var type: String?, url: String? }
        struct Item: Decodable { var title: String?, status: String?, content: Content? }
        var items: [Item]
    }

    public static func parseProjectItems(_ data: Data) throws -> [ProjectItem] {
        try JSONDecoder().decode(RawItems.self, from: data).items.map {
            ProjectItem(title: $0.title ?? "", type: $0.content?.type ?? "", status: $0.status, url: $0.content?.url)
        }
    }

    static func tail(_ s: String, bytes: Int = 12_288) -> String {
        guard s.utf8.count > bytes else { return s }
        let cut = String(decoding: s.utf8.suffix(bytes), as: UTF8.self)
        return "…\n" + (cut.firstIndex(of: "\n").map { String(cut[cut.index(after: $0)...]) } ?? cut)
    }
}
