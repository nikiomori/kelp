import Core
import Foundation
import GitKit

/// gh or glab (`tool`) failed or isn't installed, or what it answered stops Kelp: for people, `description`; the
/// command line (`args`) is there for logs.
public struct ForgeError: Error, CustomStringConvertible, Sendable {
    public var tool: String
    public var args: [String]
    public var status: Int32
    public var stderr: String

    static func notInstalled(_ tool: String, _ args: [String]) -> ForgeError {
        ForgeError(tool: tool, args: args, status: -1, stderr: "\(tool) CLI not found (brew install \(tool))")
    }

    /// What the user can act on, not the command line.
    public var description: String {
        let message = stderr.lowercased()
        if message.contains("not found (brew install gh)") {
            return "Install GitHub CLI to see pull requests and issues: brew install gh"
        }
        if message.contains("no git remotes") || message.contains("known github host") { return GitHub.noRemote }
        if message.contains("gh auth login") || message.contains("not logged in") {
            return "GitHub CLI isn't signed in — run gh auth login."
        }
        return stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? "\(tool) failed (\(status))"
    }
}

/// GitHub via the `gh` CLI; auth is whatever `gh auth` has. Every call takes the repo checkout `cwd`
/// so gh resolves owner/repo from its remotes. Blocking — call off the main thread. Its values are Core's.
extension GitHub {
    public enum PRFilter: Sendable { case open, mine, reviewRequested, closed }
    public enum MergeMethod: String, Sendable { case squash, merge, rebase }

    static let prFields =
        "number,title,url,author,headRefName,headRefOid,isDraft,state,reviewDecision,statusCheckRollup,mergeStateStatus,"
        + "updatedAt,reviewRequests"
    static let issueFields = "number,title,body,url,labels,assignees,state,author,updatedAt"

    /// Where the user's shell finds it (MacPorts, nix, mise… too), not only in the daemon's own PATH.
    /// `KELP_GH` names another program (tests use a stand-in that answers with canned JSON), like `KELP_SSH`.
    /// Looked up each time (a scan of PATH's folders): installed while Kelp runs, it works on the next try.
    static var ghPath: String? { ProcessInfo.processInfo.environment["KELP_GH"] ?? LoginPath.find("gh") }

    @discardableResult
    static func gh(_ args: [String], cwd: String) throws -> Data {
        guard let exe = ghPath else {
            throw ForgeError.notInstalled("gh", args)
        }
        do { return try Subprocess.output([exe] + args, cwd: cwd, env: Git.toolEnv) } catch let error as ProgramError {
            throw ForgeError(tool: "gh", args: args, status: error.status, stderr: error.stderr)
        }
    }

    /// For Settings: is gh installed, and who is signed in (nil: not signed in, or no network to ask).
    public static func account() -> (installed: Bool, user: String?) {
        guard let exe = ghPath else { return (false, nil) }
        let login =
            (try? Subprocess.output(
                [exe, "api", "user", "--jq", ".login"], cwd: NSHomeDirectory(), env: Git.toolEnv))
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        return (true, login?.isEmpty == false ? login : nil)
    }

    // MARK: Commands

    /// The avatar of the account behind a commit author's email, 64 px. A noreply address names its account, so that
    /// one needs no call; any other is looked up among this repo's commits (GitHub ties an email to an account only
    /// through them). nil: no account has it.
    public static func avatarURL(email: String, cwd: String) throws -> URL? {
        if let url = noreplyAvatar(email) { return url }
        let query = "repos/{owner}/{repo}/commits?author=\(GitLab.queryValue(email))&per_page=1"
        let avatar = String(
            decoding: try gh(["api", query, "--jq", ".[0].author.avatar_url // empty"], cwd: cwd), as: UTF8.self
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return avatar.isEmpty ? nil : URL(string: avatar + (avatar.contains("?") ? "&" : "?") + "s=64")
    }

    /// "123+ada@users.noreply.github.com" is account 123; the older "ada@users.noreply.github.com" is ada's.
    public static func noreplyAvatar(_ email: String) -> URL? {
        if let match = email.lowercased().wholeMatch(of: /(\d+)\+[^@]+@users\.noreply\.github\.com/) {
            return URL(string: "https://avatars.githubusercontent.com/u/\(match.1)?s=64")
        }
        if let match = email.lowercased().wholeMatch(of: /([a-z0-9-]+)@users\.noreply\.github\.com/) {
            return URL(string: "https://github.com/\(match.1).png?size=64")
        }
        return nil
    }

    public static func pullRequests(cwd: String, filter: PRFilter = .open) throws -> [PullRequest] {
        let extra: [String] =
            switch filter {
            case .open: []
            case .mine: ["--author", "@me"]
            case .reviewRequested: ["--search", "review-requested:@me"]
            case .closed: ["--state", "closed"]
            }
        let limit = filter == .closed ? "30" : "100"
        return try parsePullRequests(gh(["pr", "list", "-L", limit, "--json", prFields] + extra, cwd: cwd))
    }

    /// The newest PR whose head is `branch` (open, merged or closed), or nil.
    public static func pullRequest(cwd: String, branch: String) throws -> PullRequest? {
        try parsePullRequests(
            gh(["pr", "list", "--head", branch, "--state", "all", "-L", "1", "--json", prFields], cwd: cwd)
        ).first
    }

    public static func issues(cwd: String, mine: Bool) throws -> [Issue] {
        let extra = mine ? ["--assignee", "@me"] : []
        return try parseIssues(
            gh(
                ["issue", "list", "-L", "100", "--json", issueFields] + extra,
                cwd: cwd))
    }

    /// One pull request with its description, files and conversation, for its tab.
    public static func pullRequestView(cwd: String, number: Int) throws -> PRView {
        try parsePRView(
            gh(
                ["pr", "view", String(number), "--json", prFields + ",body,baseRefName,files,comments,reviews"],
                cwd: cwd))
    }

    /// One issue with its conversation, for its tab.
    public static func issueView(cwd: String, number: Int) throws -> IssueView {
        try parseIssueView(gh(["issue", "view", String(number), "--json", issueFields + ",comments"], cwd: cwd))
    }

    public static func checks(cwd: String, pr: Int) throws -> [Check] {
        do {
            return try parseChecks(
                gh(["pr", "checks", String(pr), "--json", "name,state,link,bucket,workflow"], cwd: cwd))
        } catch let error as ForgeError where error.stderr.contains("no checks reported") { return [] }
    }

    /// Inline review comments plus non-empty top-level review bodies.
    public static func reviewComments(cwd: String, pr: Int) throws -> [ReviewComment] {
        let inline = try parseReviewComments(
            gh(["api", "--paginate", "--slurp", "repos/{owner}/{repo}/pulls/\(pr)/comments"], cwd: cwd))
        return try parseReviews(gh(["pr", "view", String(pr), "--json", "reviews"], cwd: cwd)) + inline
    }

    /// Returns the new PR's URL. The current branch must already be pushed.
    public static func createPR(cwd: String, title: String, body: String, base: String, draft: Bool = false) throws
        -> String
    {
        let out = try gh(
            ["pr", "create", "--title", title, "--body", body, "--base", base] + (draft ? ["--draft"] : []), cwd: cwd)
        return String(decoding: out, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
    }

    /// With `head`, only while that commit is still the PR's head: what was reviewed is what lands.
    public static func mergePR(cwd: String, number: Int, method: MergeMethod, head: String? = nil) throws {
        do {
            try gh(
                ["pr", "merge", String(number), "--\(method.rawValue)"]
                    + (head.map { ["--match-head-commit", $0] } ?? []), cwd: cwd)
        } catch {
            guard head != nil, let refused = error as? ForgeError, refused.stderr.contains("Head branch was modified")
            else { throw error }
            throw ForgeError(
                tool: "gh", args: refused.args, status: refused.status,
                stderr: "#\(number) has new commits since you looked. Reload and read them before merging.")
        }
    }

    public static func projects(cwd: String) throws -> [Project] {
        let owner = try parseOwner(gh(["repo", "view", "--json", "owner"], cwd: cwd))
        return try parseProjects(gh(["project", "list", "--owner", owner, "--format", "json"], cwd: cwd))
    }

    public static func projectItems(owner: String, number: Int) throws -> [ProjectItem] {
        try parseProjectItems(
            gh(
                ["project", "item-list", String(number), "--owner", owner, "--format", "json", "-L", "200"],
                cwd: NSHomeDirectory()))
    }

    // MARK: Parsing (pure)

    private struct Login: Decodable { var login: String }
    private struct Name: Decodable { var name: String }
    private struct RawRollup: Decodable {
        var name: String?, context: String?, workflowName: String?, startedAt: String?
        var status: String?, conclusion: String?, state: String?
    }
    /// A person (login) or a team (name) asked for a review.
    private struct Reviewer: Decodable { var login: String?, name: String? }
    private struct RawPR: Decodable {
        var number: Int, title: String, url: String, author: Login, headRefName: String, headRefOid: String?
        var isDraft: Bool, state: String, reviewDecision: String?, statusCheckRollup: [RawRollup]?,
            mergeStateStatus: String?, updatedAt: String?, reviewRequests: [Reviewer]?

        var pullRequest: PullRequest {
            var pr = PullRequest(
                number: number, title: title, url: url, author: author.login, headRefName: headRefName,
                isDraft: isDraft, state: state,
                reviewDecision: reviewDecision?.isEmpty == false ? reviewDecision : nil,
                checks: summarize(statusCheckRollup ?? []), headRefOid: headRefOid)
            pr.mergeState = mergeStateStatus
            pr.updatedAt = updatedAt
            pr.reviewRequests = reviewRequests?.compactMap { $0.login ?? $0.name }
            return pr
        }
    }

    static func parsePullRequests(_ data: Data) throws -> [PullRequest] {
        try JSONDecoder().decode([RawPR].self, from: data).map(\.pullRequest)
    }

    private struct RawThreadComment: Decodable {
        var author: Login?, body: String, createdAt: String?, submittedAt: String?, state: String?
        var comment: Comment {
            Comment(
                author: author?.login ?? "ghost", body: body, createdAt: createdAt ?? submittedAt ?? "",
                review: state)
        }
    }
    private struct RawPRView: Decodable {
        var body: String?, baseRefName: String, files: [ChangedFile]?, comments: [RawThreadComment]?,
            reviews: [RawThreadComment]?
    }

    /// Comments and the reviews that said something or decided, oldest first.
    static func parsePRView(_ data: Data) throws -> PRView {
        let pr = try JSONDecoder().decode(RawPR.self, from: data).pullRequest
        let view = try JSONDecoder().decode(RawPRView.self, from: data)
        let reviews = (view.reviews ?? []).filter { !$0.body.isEmpty || $0.state != "COMMENTED" }
        let said = ((view.comments ?? []) + reviews).map(\.comment).sorted { $0.createdAt < $1.createdAt }
        return PRView(
            pr: pr, body: view.body ?? "", baseRefName: view.baseRefName, files: view.files ?? [], comments: said)
    }

    private struct RawIssueView: Decodable { var comments: [RawThreadComment]? }
    static func parseIssueView(_ data: Data) throws -> IssueView {
        let issue = try JSONDecoder().decode(RawIssue.self, from: data).issue
        let comments = try JSONDecoder().decode(RawIssueView.self, from: data).comments ?? []
        return IssueView(issue: issue, comments: comments.map(\.comment))
    }

    /// The rollup keeps check runs from superseded workflow runs; count only the latest per workflow/name.
    private static func summarize(_ rollup: [RawRollup]) -> PullRequest.Checks {
        var latest: [String: RawRollup] = [:]
        for check in rollup {
            let key = "\(check.workflowName ?? "")/\(check.name ?? check.context ?? "")"
            if let old = latest[key], (old.startedAt ?? "") > (check.startedAt ?? "") { continue }
            latest[key] = check
        }
        var checks = PullRequest.Checks()
        for check in latest.values {
            // CheckRun has status+conclusion; StatusContext has only state.
            switch check.status.map({ $0 == "COMPLETED" ? check.conclusion ?? "" : "PENDING" }) ?? check.state ?? "" {
            case "SUCCESS": checks.passed += 1
            case "PENDING", "EXPECTED": checks.pending += 1
            case "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": checks.failed += 1
            default: break   // NEUTRAL, SKIPPED, STALE
            }
        }
        return checks
    }

    private struct RawIssue: Decodable {
        var number: Int, title: String, body: String?, url: String, labels: [Name], assignees: [Login], state: String
        var author: Login?, updatedAt: String?
        var issue: Issue {
            var issue = Issue(
                number: number, title: title, body: body ?? "", url: url, labels: labels.map(\.name),
                assignees: assignees.map(\.login), state: state)
            issue.author = author?.login
            issue.updatedAt = updatedAt
            return issue
        }
    }

    static func parseIssues(_ data: Data) throws -> [Issue] {
        try JSONDecoder().decode([RawIssue].self, from: data).map(\.issue)
    }

    static func parseChecks(_ data: Data) throws -> [Check] {
        try JSONDecoder().decode([Check].self, from: data).map {
            var check = $0
            check.runId = runId(fromLink: check.link)
            return check
        }
    }

    /// `https://github.com/o/r/actions/runs/123/job/456` -> 123
    public static func runId(fromLink link: String) -> Int? {
        (link.firstMatch(of: #/actions/runs/(\d+)/#)?.1).flatMap { Int($0) }
    }

    private struct RawComment: Decodable {
        var path: String, line: Int?, original_line: Int?, body: String, user: Login, html_url: String
    }

    /// Input is `gh api --paginate --slurp` output: an array of pages.
    static func parseReviewComments(_ data: Data) throws -> [ReviewComment] {
        try JSONDecoder().decode([[RawComment]].self, from: data).joined().map {
            ReviewComment(
                path: $0.path, line: $0.line ?? $0.original_line, body: $0.body, author: $0.user.login, url: $0.html_url
            )
        }
    }

    private struct RawReviews: Decodable {
        struct Review: Decodable {
            var author: Login?
            var body: String
        }
        var reviews: [Review]
    }

    static func parseReviews(_ data: Data) throws -> [ReviewComment] {
        try JSONDecoder().decode(RawReviews.self, from: data).reviews.filter { !$0.body.isEmpty }.map {
            ReviewComment(path: nil, line: nil, body: $0.body, author: $0.author?.login ?? "ghost", url: nil)
        }
    }

    private struct RawOwner: Decodable { var owner: Login }
    static func parseOwner(_ data: Data) throws -> String {
        try JSONDecoder().decode(RawOwner.self, from: data).owner.login
    }

    private struct RawProjects: Decodable { var projects: [Project] }
    static func parseProjects(_ data: Data) throws -> [Project] {
        try JSONDecoder().decode(RawProjects.self, from: data).projects
    }

    private struct RawItems: Decodable {
        struct Content: Decodable { var type: String?, url: String? }
        struct Item: Decodable { var title: String?, status: String?, content: Content? }
        var items: [Item]
    }

    static func parseProjectItems(_ data: Data) throws -> [ProjectItem] {
        try JSONDecoder().decode(RawItems.self, from: data).items.map {
            ProjectItem(title: $0.title ?? "", type: $0.content?.type ?? "", status: $0.status, url: $0.content?.url)
        }
    }

    static func tail(_ text: String, bytes: Int = 12_288) -> String {
        guard text.utf8.count > bytes else { return text }
        let cut = String(decoding: text.utf8.suffix(bytes), as: UTF8.self)
        return "…\n" + (cut.firstIndex(of: "\n").map { String(cut[cut.index(after: $0)...]) } ?? cut)
    }
}
