import Foundation
import Testing
import Core
@testable import Integrations

private func d(_ s: String) -> Data { Data(s.utf8) }

@Test func parsePullRequestsSummarizesChecks() throws {
    let json = """
    [{"author":{"id":"U_1","is_bot":false,"login":"alice","name":"Alice"},"headRefName":"123-fix","isDraft":false,"number":7,
      "reviewDecision":"REVIEW_REQUIRED","state":"OPEN","title":"Fix","url":"https://github.com/o/r/pull/7",
      "statusCheckRollup":[
        {"__typename":"CheckRun","conclusion":"FAILURE","name":"lint","startedAt":"2026-10-14T04:39:00Z","status":"COMPLETED","workflowName":"Lint"},
        {"__typename":"CheckRun","conclusion":"SUCCESS","name":"lint","startedAt":"2026-10-15T04:39:00Z","status":"COMPLETED","workflowName":"Lint"},
        {"__typename":"CheckRun","conclusion":"FAILURE","name":"test","startedAt":"2026-10-15T04:39:00Z","status":"COMPLETED","workflowName":"CI"},
        {"__typename":"CheckRun","conclusion":"","name":"build","startedAt":"2026-10-15T04:39:00Z","status":"IN_PROGRESS","workflowName":"CI"},
        {"__typename":"CheckRun","conclusion":"SKIPPED","name":"triage","startedAt":"2026-10-15T04:39:00Z","status":"COMPLETED","workflowName":"T"},
        {"__typename":"StatusContext","context":"ci/circle","state":"PENDING"}]},
     {"author":{"login":"bob"},"headRefName":"b","isDraft":true,"number":8,"reviewDecision":"","state":"OPEN","title":"WIP",
      "url":"https://github.com/o/r/pull/8","statusCheckRollup":[]}]
    """
    let prs = try GitHub.parsePullRequests(d(json))
    #expect(prs.count == 2)
    #expect(prs[0] == GitHub.PullRequest(number: 7, title: "Fix", url: "https://github.com/o/r/pull/7", author: "alice", headRefName: "123-fix",
                                         isDraft: false, state: "OPEN", reviewDecision: "REVIEW_REQUIRED",
                                         checks: .init(passed: 1, failed: 1, pending: 2)))
    #expect(prs[1].reviewDecision == nil && prs[1].isDraft && prs[1].checks == .init())
}

@Test func parseIssuesFlattensLabelsAndAssignees() throws {
    let json = """
    [{"assignees":[{"id":"U_1","login":"alice","name":"Alice"}],"body":"Steps","labels":[{"id":"L","name":"bug","description":"","color":"D6393F"}],
      "number":12,"state":"OPEN","title":"Crash","url":"https://github.com/o/r/issues/12"}]
    """
    #expect(try GitHub.parseIssues(d(json)) == [GitHub.Issue(number: 12, title: "Crash", body: "Steps", url: "https://github.com/o/r/issues/12",
                                                            labels: ["bug"], assignees: ["alice"], state: "OPEN")])
}

@Test func parseChecksExtractsRunId() throws {
    let json = """
    [{"bucket":"fail","link":"https://github.com/cli/cli/actions/runs/39045086480/job/117432139361","name":"test","state":"FAILURE","workflow":"CI"},
     {"bucket":"pass","link":"https://ci.example.com/x","name":"ext","state":"SUCCESS","workflow":""}]
    """
    let c = try GitHub.parseChecks(d(json))
    #expect(c.map(\.runId) == [39045086480, nil])
    #expect(c[0].bucket == "fail" && c[0].workflow == "CI")
}

@Test func parseReviewCommentsAndReviews() throws {
    let comments = """
    [[{"path":"a.go","line":null,"original_line":10,"body":"nit","user":{"login":"bob","id":1},"html_url":"https://github.com/o/r/pull/1#discussion_r1"}],
     [{"path":"b.go","line":3,"original_line":3,"body":"why?","user":{"login":"amy"},"html_url":"https://github.com/o/r/pull/1#discussion_r2"}]]
    """
    let c = try GitHub.parseReviewComments(d(comments))
    #expect(c.map(\.line) == [10, 3] && c[1].author == "amy" && c[0].path == "a.go")

    let reviews = """
    {"reviews":[{"id":"PRR_1","author":{"login":"bob"},"body":"Please fix","state":"CHANGES_REQUESTED","submittedAt":"2026-10-16T21:22:40Z"},
                {"id":"PRR_2","author":{"login":"amy"},"body":"","state":"APPROVED"}]}
    """
    #expect(try GitHub.parseReviews(d(reviews)) == [GitHub.ReviewComment(path: nil, line: nil, body: "Please fix", author: "bob", url: nil)])
}

@Test func parseProjectsAndItems() throws {
    #expect(try GitHub.parseOwner(d(#"{"owner":{"id":"O_1","login":"acme"}}"#)) == "acme")
    let projects = """
    {"projects":[{"closed":false,"fields":{"totalCount":9},"id":"PVT_1","items":{"totalCount":2},"number":3,
      "owner":{"login":"acme","type":"Organization"},"public":false,"readme":"","shortDescription":"","title":"Roadmap",
      "url":"https://github.com/orgs/acme/projects/3"}],"totalCount":1}
    """
    #expect(try GitHub.parseProjects(d(projects)) == [GitHub.Project(number: 3, title: "Roadmap", url: "https://github.com/orgs/acme/projects/3")])
    let items = """
    {"items":[{"content":{"body":"","number":5,"repository":"acme/r","title":"Login","type":"Issue","url":"https://github.com/acme/r/issues/5"},
               "id":"PVTI_1","repository":"https://github.com/acme/r","status":"In Progress","title":"Login"},
              {"content":{"body":"","title":"Idea","type":"DraftIssue"},"id":"PVTI_2","title":"Idea"}],"totalCount":2}
    """
    #expect(try GitHub.parseProjectItems(d(items)) == [
        GitHub.ProjectItem(title: "Login", type: "Issue", status: "In Progress", url: "https://github.com/acme/r/issues/5"),
        GitHub.ProjectItem(title: "Idea", type: "DraftIssue", status: nil, url: nil)
    ])
}

@Test func tailKeepsLastBytesFromLineStart() {
    #expect(GitHub.tail("short") == "short")
    let s = (1...5000).map { "line \($0)" }.joined(separator: "\n")
    let t = GitHub.tail(s)
    #expect(t.utf8.count <= 12_288 + 4 && t.hasPrefix("…\nline ") && t.hasSuffix("line 5000"))
}

@Test func linearParseIssues() throws {
    let json = """
    {"data":{"viewer":{"assignedIssues":{"nodes":[{"id":"uuid-1","identifier":"ENG-123","title":"Fix login","description":null,
      "url":"https://linear.app/acme/issue/ENG-123/fix-login","branchName":"alice/eng-123-fix-login",
      "state":{"id":"s1","name":"Todo","type":"unstarted"},"team":{"id":"t1","key":"ENG","name":"Engineering"}}]}}}}
    """
    let issues = try LinearClient.parse([LinearIssue].self, from: d(json), at: "viewer", "assignedIssues", "nodes")
    #expect(issues == [LinearIssue(id: "uuid-1", identifier: "ENG-123", title: "Fix login", description: nil,
                                   url: "https://linear.app/acme/issue/ENG-123/fix-login",
                                   state: LinearState(id: "s1", name: "Todo", type: "unstarted"),
                                   team: LinearTeam(id: "t1", key: "ENG", name: "Engineering"), branchName: "alice/eng-123-fix-login")])
    #expect(try LinearClient.parse(Bool.self, from: d(#"{"data":{"issueUpdate":{"success":true}}}"#), at: "issueUpdate", "success"))
}

@Test func linearParseErrors() {
    let err = #"{"errors":[{"message":"Authentication required","extensions":{"code":"AUTHENTICATION_ERROR"}}],"data":null}"#
    #expect(throws: IntegrationError.self) { try LinearClient.parse([LinearTeam].self, from: d(err), at: "teams", "nodes") }
    #expect(throws: IntegrationError.self) { try LinearClient.parse([LinearTeam].self, from: d(#"{"data":{"team":null}}"#), at: "team", "states") }
}

@Test func linearStateFor() throws {
    let json = """
    {"data":{"team":{"states":{"nodes":[{"id":"1","name":"Backlog","type":"backlog"},{"id":"2","name":"In Review","type":"started"},
      {"id":"3","name":"In Progress","type":"started"},{"id":"4","name":"Canceled","type":"canceled"},{"id":"5","name":"Done","type":"completed"}]}}}}
    """
    let states = try LinearClient.parse([LinearState].self, from: d(json), at: "team", "states", "nodes")
    #expect(LinearClient.stateFor(kind: .inProgress, in: states)?.id == "3")
    #expect(LinearClient.stateFor(kind: .inReview, in: states)?.id == "2")
    #expect(LinearClient.stateFor(kind: .done, in: states)?.id == "5")
    let bare = states.filter { $0.id != "2" && $0.id != "3" } + [LinearState(id: "6", name: "Doing", type: "started")]
    #expect(LinearClient.stateFor(kind: .inProgress, in: bare)?.id == "6")
    #expect(LinearClient.stateFor(kind: .inReview, in: bare) == nil)
}

@Test func issueRefBranchNames() {
    #expect(IssueRef.branchName("123", title: "Fix the login crash on macOS Sonoma 14.5!") == "123-fix-the-login-crash-on-macos")
    #expect(IssueRef.branchName("#45", title: "Café résumé — naïve") == "45-cafe-resume-naive")
    #expect(IssueRef.branchName("ENG-9", title: "") == "eng-9")
}

@Test func jiraParsing() throws {
    let search = #"{"issues":[{"key":"ENG-7","fields":{"summary":"Fix login","status":{"name":"In Progress","statusCategory":{"key":"indeterminate"}},"#
        + #""issuetype":{"name":"Bug"},"project":{"key":"ENG"},"#
        + #""description":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Steps:"}]},"#
        + #"{"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"open app"}]}]}]}]}}}]}"#
    let issues = try JiraClient.parseSearch(Data(search.utf8), site: "https://acme.atlassian.net/")
    #expect(issues.count == 1)
    #expect(issues[0].key == "ENG-7" && issues[0].statusCategory == "indeterminate" && issues[0].url == "https://acme.atlassian.net/browse/ENG-7")
    #expect(issues[0].description.contains("Steps:") && issues[0].description.contains("- open app"))
    let tr = #"{"transitions":[{"id":"31","name":"In Review","to":{"statusCategory":{"key":"indeterminate"}}},{"id":"41","name":"Done","to":{"statusCategory":{"key":"done"}}}]}"#
    let ts = try JiraClient.parseTransitions(Data(tr.utf8))
    #expect(ts.map(\.id) == ["31", "41"] && ts[1].toCategory == "done")
}

@Test func bitbucketParsing() throws {
    #expect(BitbucketClient.slug(remote: "git@bitbucket.org:team/repo.git")! == ("team", "repo"))
    #expect(BitbucketClient.slug(remote: "https://user@bitbucket.org/team/repo")! == ("team", "repo"))
    #expect(BitbucketClient.slug(remote: "git@github.com:a/b.git") == nil)
    // Only bitbucket.org as the host: a path or another host that merely contains it isn't Bitbucket.
    #expect(BitbucketClient.slug(remote: "https://example.com/bitbucket.org/team/repo") == nil)
    #expect(BitbucketClient.slug(remote: "git@github.com:me/bitbucket.org-mirror.git") == nil)
    #expect(BitbucketClient.slug(remote: "https://notbitbucket.org/team/repo") == nil)
    #expect(BitbucketClient.slug(remote: "ssh://git@bitbucket.org/team/repo.git")! == ("team", "repo"))
    let prs = #"{"values":[{"id":12,"title":"Add API","state":"OPEN","draft":false,"author":{"display_name":"Ann"},"source":{"branch":{"name":"feat/api"}},"links":{"html":{"href":"https://bitbucket.org/team/repo/pull-requests/12"}}}]}"#
    let p = try BitbucketClient.parsePullRequests(Data(prs.utf8))
    #expect(p.count == 1 && p[0].number == 12 && p[0].headRefName == "feat/api" && p[0].author == "Ann")
}

@Test func ghErrorsSayWhatToDo() {
    #expect(GitHubError(args: ["pr", "list"], status: 1, stderr: "no git remotes found").description == "This project has no GitHub remote.")
    #expect(GitHubError(args: [], status: 4, stderr: "To get started with GitHub CLI, please run:  gh auth login").description.contains("gh auth login"))
    #expect(!GitHubError(args: ["pr", "list", "--json", "number"], status: 1, stderr: "boom\nmore").description.contains("--json"))
}

@Test func workflowDispatchInputs() {
    let y = """
    name: Deploy
    on:
      push:
      workflow_dispatch:
        inputs:
          environment:
            description: "Where to"
            default: staging
            type: choice
            options:
              - staging
              - production
          dry_run:
            required: true
    jobs:
      x:
        runs-on: ubuntu-latest
    """
    let w = CIRuns.parseWorkflow(y, file: "deploy.yml")
    #expect(w?.name == "Deploy")
    #expect(w?.inputs.map(\.name) == ["environment", "dry_run"])
    #expect(w?.inputs.first?.options == ["staging", "production"])
    #expect(w?.inputs.first?.defaultValue == "staging")
    #expect(w?.inputs.last?.required == true)
    #expect(CIRuns.parseWorkflow("on: push\n", file: "a.yml") == nil)
}

@Test func ciLogReadsAsText() {
    let raw = """
    Deploy\tSet up job\t\u{FEFF}2026-10-20T07:01:36.8612524Z ##[group]Run ssh-action
    Deploy\tSet up job\t2026-10-20T07:01:36.86Z ##[endgroup]
    Deploy\tRun deploy\t2026-10-20T07:03:31.02Z err: ^[[0m^[[4m>>>> compose\u{1B}[0m
    Deploy\tRun deploy\t2026-10-20T07:03:33.08Z ##[error]Process completed with exit code 2.
    """
    #expect(CIRuns.readable(raw) == "▸ Set up job\nRun ssh-action\n\n▸ Run deploy\nerr: >>>> compose\nError: Process completed with exit code 2.")
    #expect(CIRuns.readable("plain line\n") == "plain line\n")   // GitLab's trace has no columns
}

/// GitLab's merge request JSON reads as a pull request, its pipeline as checks.
@Test func gitlabMergeRequestShape() throws {
    let json = #"""
    [{"iid": 12, "title": "Fix login", "web_url": "https://gitlab.com/a/b/-/merge_requests/12", "author": {"username": "kim"},
      "source_branch": "fix-login", "state": "opened", "draft": true, "head_pipeline": {"status": "failed"}}]
    """#
    let pr = try #require(try JSONDecoder().decode([GitLab.RawMR].self, from: Data(json.utf8)).map(GitLab.pr).first)
    #expect(pr.number == 12 && pr.state == "OPEN" && pr.isDraft && pr.author == "kim" && pr.headRefName == "fix-login")
    #expect(pr.checks.failed == 1 && pr.checks.passed == 0)
    #expect(CIRuns.gitlabState("manual").0 == "waiting" && CIRuns.gitlabState("canceled").1 == "cancelled")
}

@Test func ciStateIsTheNewestRunOfEachWorkflowMostPressingFirst() {
    func run(_ workflow: String, _ status: String, _ conclusion: String? = nil) -> CIRuns.Run {
        CIRuns.Run(id: 0, title: "", workflow: workflow, status: status, conclusion: conclusion, event: "push", url: "", createdAt: "")
    }
    let ok = run("CI", "completed", "success"), broke = run("CI", "completed", "failure")
    #expect(CIRuns.state([]) == nil)
    #expect(CIRuns.state([ok, broke]) == .passed)   // newest first: the failure was fixed since
    #expect(CIRuns.state([run("Deploy", "in_progress"), ok]) == .running)
    #expect(CIRuns.state([run("Deploy", "waiting"), run("Lint", "queued"), ok]) == .waiting)
    #expect(CIRuns.state([run("Deploy", "waiting"), broke]) == .failed)
    #expect(CIRuns.state([run("Fork", "completed", "action_required")]) == .waiting)
    #expect(CIRuns.state([run("CI", "completed", "skipped"), run("Deploy", "completed", "cancelled")]) == nil)
    #expect(CIRuns.state(GitHub.PullRequest.Checks(passed: 3, failed: 0, pending: 1)) == .running)
    #expect(CIRuns.state(GitHub.PullRequest.Checks()) == nil)
    #expect([CIRuns.State.running, .passed, .failed].max() == .failed)
}

@Test func gitlabIsRecognisedByTheHostNotAWordInThePath() {
    #expect(GitLab.isGitLab(remote: "git@gitlab.com:g/r.git"))
    #expect(GitLab.isGitLab(remote: "https://gitlab.example.org/g/r"))
    #expect(!GitLab.isGitLab(remote: "https://github.com/firecow/gitlab-ci-local.git"))   // a GitHub repo named after GitLab
    #expect(!GitLab.isGitLab(remote: "git@github.com:me/gitlab-mirror.git"))
    #expect(!GitLab.isGitLab(remote: ""))
}

@Test func glabAuthStatusNamesWhoIsSignedInOnEachHost() {
    let status = """
    gitlab.com
      ✓ Logged in to gitlab.com as ada (/Users/ada/.config/glab-cli/config.yml)
      ✓ Git operations for gitlab.com configured to use ssh protocol.
    git.acme.dev
      ✓ Logged in to git.acme.dev as ada.l (/Users/ada/.config/glab-cli/config.yml)
    """
    #expect(GitLab.signedIn(status) == "ada on gitlab.com, ada.l on git.acme.dev")
    #expect(GitLab.signedIn("x gitlab.com has not been authenticated with glab. Run `glab auth login gitlab.com`") == nil)
}

@Test func gitlabBranchNamesStayOneQueryValue() {
    #expect(GitLab.queryValue("fix+x") == "fix%2Bx")          // "+" would read as a space
    #expect(GitLab.queryValue("a&b=c") == "a%26b%3Dc")        // & and = would start another parameter
    #expect(GitLab.queryValue("feat/login") == "feat%2Flogin")
    #expect(GitLab.queryValue("plain-name_1.2~x") == "plain-name_1.2~x")
}

@Test func aNoreplyAddressNamesItsGitHubAccount() {
    #expect(GitHub.noreplyAvatar("129620956+Ada@users.noreply.github.com")?.absoluteString == "https://avatars.githubusercontent.com/u/129620956?s=64")
    #expect(GitHub.noreplyAvatar("ada@users.noreply.github.com")?.absoluteString == "https://github.com/ada.png?size=64")
    #expect(GitHub.noreplyAvatar("ada@example.com") == nil)
}
