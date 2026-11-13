import Core
import Foundation
import GitKit
import Testing

@testable import Daemon

/// A stand-in for `gh`: logs its arguments, answers with canned JSON. Set up once, before anything asks for gh.
private let fakeGh: (log: String, script: String) = {
    let dir = tmp(), log = dir.appendingPathComponent("gh.log").path, script = dir.appendingPathComponent("gh").path
    let body = """
        #!/bin/sh
        echo "$@" >> '\(log)'
        case "$1 $2" in
          "pr list") echo '[{"author":{"login":"ada"},"headRefName":"feat/x","isDraft":false,"number":7,"reviewDecision":"APPROVED","state":"OPEN","title":"Add login","url":"https://github.com/o/r/pull/7","statusCheckRollup":[]}]';;
          "issue list") echo '[{"assignees":[{"login":"ada"}],"body":"Steps","labels":[{"name":"bug"}],"number":3,"state":"OPEN","title":"Crash","url":"https://github.com/o/r/issues/3"}]';;
          "pr checks") if [ "$3" = "404" ]; then echo "no checks reported on the 'x' branch" >&2; exit 1; fi
                       echo '[{"bucket":"fail","link":"https://github.com/o/r/actions/runs/99/job/1","name":"test","state":"FAILURE","workflow":"CI"}]';;
          "run view") case "$*" in
                        *"--json jobs"*) echo '{"jobs":[{"databaseId":5,"name":"build","status":"completed","conclusion":"failure","url":"https://github.com/o/r/actions/runs/99/job/5",\
        "steps":[{"name":"Compile","status":"completed","conclusion":"failure"}]}]}';;
                        *"--job"*"--log-failed"*) printf 'build\\tCompile\\t2026-10-20T10:00:00Z error: boom\\n';;
                        *) printf 'step 1\\nstep 2 failed\\n';;
                      esac;;
          "run list") echo '[{"databaseId":99,"displayTitle":"Add login","workflowName":"CI","status":"completed","conclusion":"failure","event":"push","url":"https://github.com/o/r/actions/runs/99","createdAt":"2026-10-20T10:00:00Z"}]';;
          "run rerun"|"run cancel"|"workflow run") ;;
          "pr merge") case "$*" in *"--match-head-commit old"*) echo "GraphQL: Head branch was modified. Review and try the merge again." >&2; exit 1;; esac;;
          "pr create") echo "Creating pull request"; echo "https://github.com/o/r/pull/8";;
          "repo view") echo '{"owner":{"id":"O_1","login":"acme"}}';;
          "project list") echo '{"projects":[{"closed":false,"id":"PVT_1","number":3,"owner":{"login":"acme"},"title":"Roadmap","url":"https://github.com/orgs/acme/projects/3"}],"totalCount":1}';;
          "project item-list") echo '{"items":[{"content":{"type":"Issue","url":"https://github.com/acme/r/issues/5"},"id":"I1","status":"In Progress","title":"Login"},\
        {"content":{"type":"DraftIssue"},"id":"I2","title":"Idea"}],"totalCount":2}';;
          "pr view") case "$*" in
                       *baseRefName*) echo '{"author":{"login":"ada"},"headRefName":"feat/x","isDraft":false,\
        "number":7,"state":"OPEN","title":"Add login","url":"https://github.com/o/r/pull/7","body":"Adds it","baseRefName":"main",\
        "files":[{"path":"a.swift","additions":3,"deletions":1}],\
        "comments":[{"author":{"login":"bob"},"body":"Nice","createdAt":"2026-10-20T10:00:00Z"}],"reviews":[]}';;
                       *) echo '{"reviews":[{"id":"R1","author":{"login":"bob"},"body":"Please rename","state":"CHANGES_REQUESTED"}]}';;
                     esac;;
          "issue view") echo '{"assignees":[],"body":"Steps","labels":[],"number":3,"state":"OPEN","title":"Crash",\
        "url":"https://github.com/o/r/issues/3","author":{"login":"amy"},\
        "comments":[{"author":{"login":"ada"},"body":"Seen it","createdAt":"2026-10-21T10:00:00Z"}]}';;
          "api --paginate") echo '[[{"path":"a.swift","line":3,"original_line":3,"body":"nit","user":{"login":"amy"},"html_url":"https://github.com/o/r/pull/7#r1"}]]';;
          "api user") echo ada;;
          *) echo "unexpected: $*" >&2; exit 1;;
        esac
        """
    try? body.write(toFile: script, atomically: true, encoding: .utf8)
    chmod(script, 0o755)
    setenv("KELP_GH", script, 1)
    return (log, script)
}()
private func calls() -> [String] {
    ((try? String(contentsOfFile: fakeGh.log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}

private func rig() async throws -> World {
    _ = fakeGh
    return try await world()
}

@Test func theDaemonListsPullRequestsFromGh() async throws {
    let r = try await rig()
    defer { r.d.stop() }
    let prs = try await r.c.call("github.prs", .obj(["repoId": .string(r.repo.id)])).array ?? []
    #expect(
        prs.count == 1 && prs[0]["number"]?.int == 7 && prs[0]["author"]?.string == "ada"
            && prs[0]["reviewDecision"]?.string == "APPROVED")
    #expect(calls().contains { $0.hasPrefix("pr list") && $0.contains("--json") })
}

/// A PR's and an issue's own tab: what they say, what the PR changes, and the conversation.
@Test func aPullRequestAndAnIssueAreReadWhole() async throws {
    let r = try await rig()
    defer { r.d.stop() }
    let pr = try await r.c.call(GitHubPRView(repoId: r.repo.id, pr: 7))
    #expect(pr.body == "Adds it" && pr.baseRefName == "main" && pr.files.first?.additions == 3)
    #expect(pr.comments.map(\.author) == ["bob"] && pr.pr.number == 7)
    #expect(calls().contains { $0.hasPrefix("pr view 7") && $0.contains("files") })
    let issue = try await r.c.call(GitHubIssueView(repoId: r.repo.id, issue: 3))
    #expect(issue.issue.author == "amy" && issue.comments.first?.body == "Seen it")
    _ = try await r.c.call("github.prs", .obj(["repoId": .string(r.repo.id), "filter": "closed"]))
    #expect(calls().filter { $0.hasPrefix("pr list") }.last?.contains("--state closed") == true)
}

@Test func issuesAskForMineOnlyWhenToldTo() async throws {
    let r = try await rig()
    defer { r.d.stop() }
    let all = try await r.c.call("github.issues", .obj(["repoId": .string(r.repo.id)])).array ?? []
    #expect(all.first?["labels"]?.array?.first?.string == "bug")
    let before = calls().filter { $0.hasPrefix("issue list") }
    #expect(before.last?.contains("--assignee") == false)
    _ = try await r.c.call("github.issues", .obj(["repoId": .string(r.repo.id), "filter": "mine"]))
    #expect(calls().filter { $0.hasPrefix("issue list") }.last?.contains("--assignee @me") == true)
}

@Test func checksComeBackAndNoChecksIsAnEmptyListNotAnError() async throws {
    let r = try await rig()
    defer { r.d.stop() }
    let checks = try await r.c.call("github.checks", .obj(["repoId": .string(r.repo.id), "pr": 7])).array ?? []
    #expect(checks.first?["runId"]?.int == 99 && checks.first?["bucket"]?.string == "fail")
    #expect(
        try await r.c.call("github.checks", .obj(["repoId": .string(r.repo.id), "pr": 404])).array?.isEmpty == true)
}

@Test func aFailedRunsLogIsTextFromGh() async throws {
    let r = try await rig()
    defer { r.d.stop() }
    let log = try await r.c.call("github.failedLog", .obj(["repoId": .string(r.repo.id), "runId": 99])).string ?? ""
    #expect(log.contains("step 2 failed"))
    #expect(calls().contains("run view 99 --log-failed"))
}

@Test func githubStatusSaysWhoIsSignedIn() async throws {
    let r = try await rig()
    defer { r.d.stop() }
    let s = try await r.c.call("github.status")
    #expect(s["installed"]?.bool == true && s["user"]?.string == "ada")
}

@Test func gitlabStatusSaysWhoIsSignedIn() async throws {
    _ = fakeGlab
    let r = try await rig()
    defer { r.d.stop() }
    let s = try await r.c.call(GitLabStatus())
    #expect(s.installed && s.user == "ada on gitlab.example.com")
}

@Test func theBranchsPullRequestIsCachedForTwoMinutes() async throws {
    let r = try await rig()
    defer { r.d.stop() }
    let wt = try await workspace(r, "feat/x")
    let n0 = calls().filter { $0.contains("--head feat/x") }.count
    let first = try await r.c.call("github.branchPR", .obj(["worktreeId": .string(wt.id)]))
    #expect(first["number"]?.int == 7)
    _ = try await r.c.call("github.branchPR", .obj(["worktreeId": .string(wt.id)]))
    #expect(calls().filter { $0.contains("--head feat/x") }.count == n0 + 1)   // the second answer didn't ask gh again
}

@Test func theForgeIsGithubForAPlainRepo() async throws {
    let r = try await rig()
    defer { r.d.stop() }
    #expect(try await r.c.call("github.forge", .obj(["repoId": .string(r.repo.id)])).string == "github")
}

@Test func ciRunsJobsLogsAndRerunsGoThroughGh() async throws {
    let r = try await rig()
    defer { r.d.stop() }
    let wt = try await workspace(r, "feat/x")
    let runs = try await r.c.call("ci.runs", .obj(["worktreeId": .string(wt.id)]))
    #expect(
        runs["branch"]?.string == "feat/x" && runs["runs"]?.array?.first?["id"]?.int == 99
            && runs["runs"]?.array?.first?["conclusion"]?.string == "failure")
    let jobs = try await r.c.call("ci.jobs", .obj(["worktreeId": .string(wt.id), "run": 99])).array ?? []
    #expect(jobs.first?["name"]?.string == "build" && jobs.first?["steps"]?.array?.first?["name"]?.string == "Compile")
    let log = try await r.c.call("ci.log", .obj(["worktreeId": .string(wt.id), "job": 5])).string ?? ""
    #expect(log.contains("error: boom") && !log.contains("2026-10-20T10:00:00Z"))   // the timestamp column is stripped
    let full = try await r.c.call(CIFullLog(worktreeId: wt.id, job: 5))
    #expect(full.contains("step 2 failed") && calls().contains("run view --job 5 --log"))   // the whole log, not its failures
    let report = try await r.c.call("ci.failures", .obj(["worktreeId": .string(wt.id), "job": 5]))
    #expect(report["log"]?.string?.contains("error: boom") == true)
    _ = try await r.c.call("ci.rerun", .obj(["worktreeId": .string(wt.id), "run": 99]))
    #expect(calls().contains("run rerun 99 --failed"))
    _ = try await r.c.call("ci.rerunAll", .obj(["worktreeId": .string(wt.id), "run": 99]))
    _ = try await r.c.call("ci.rerunJob", .obj(["worktreeId": .string(wt.id), "job": 5]))
    _ = try await r.c.call("ci.cancel", .obj(["worktreeId": .string(wt.id), "run": 99]))
    #expect(calls().contains("run rerun 99"))
    #expect(calls().contains("run rerun --job 5") && calls().contains("run cancel 99"))
    _ = try await r.c.call(
        "ci.dispatch",
        .obj([
            "worktreeId": .string(wt.id), "workflow": "ci.yml", "branch": "feat/x",
            "inputs": .object(["b": "2", "a": "1"])
        ]))
    #expect(calls().contains("workflow run --ref feat/x -f a=1 -f b=2 -- ci.yml"))   // inputs in a stable order
    // The repository names its workflow files: one that reads as an option stays a name.
    _ = try await r.c.call(
        "ci.dispatch", .obj(["worktreeId": .string(wt.id), "workflow": "-Fx=@/etc/passwd.yml", "branch": "feat/x"]))
    #expect(calls().contains("workflow run --ref feat/x -- -Fx=@/etc/passwd.yml"))
}

@Test func reviewCommentsMergeReviewsAndInlineComments() async throws {
    let r = try await rig()
    defer { r.d.stop() }
    let c = try await r.c.call("github.reviewComments", .obj(["repoId": .string(r.repo.id), "pr": 7])).array ?? []
    #expect(c.compactMap { $0["author"]?.string }.sorted() == ["amy", "bob"])
    #expect(c.first { $0["author"]?.string == "amy" }?["path"]?.string == "a.swift")
}

@Test func projectBoardsAndTheirItemsComeFromGh() async throws {
    let r = try await rig()
    defer { r.d.stop() }
    let projects = try await r.c.call("github.projects", .obj(["repoId": .string(r.repo.id)])).array ?? []
    #expect(projects.first?["number"]?.int == 3 && projects.first?["title"]?.string == "Roadmap")
    #expect(calls().contains { $0.hasPrefix("project list --owner acme") })   // the owner comes from the repo
    let items = try await r.c.call("github.projectItems", .obj(["owner": "acme", "number": 3])).array ?? []
    #expect(items.map { $0["title"]?.string } == ["Login", "Idea"] && items.first?["status"]?.string == "In Progress")
    #expect(calls().contains { $0.hasPrefix("project item-list 3 --owner acme") })
    await #expect(throws: (any Error).self) { _ = try await r.c.call("github.projectItems", .obj([:])) }   // the owner is required
}

/// A stand-in for `glab`: logs its arguments, answers the merge-request API.
private let fakeGlab: String = {
    let dir = tmp(), log = dir.appendingPathComponent("glab.log").path, script = dir.appendingPathComponent("glab").path
    try? """
    #!/bin/sh
    echo "$@" >> '\(log)'
    case "$*" in
      *"-X POST projects/:id/merge_requests"*) echo '{"iid":12,"title":"t","web_url":"https://gitlab.example.com/g/r/-/merge_requests/12","author":{"username":"ada"},"source_branch":"feat/mr","state":"opened"}';;
      *"-X PUT projects/:id/merge_requests/12/merge"*) echo '{"state":"merged"}';;
      *"merge_requests?state=opened"*) echo '[{"iid":4,"title":"Fix y","web_url":"https://gitlab.example.com/g/r/-/merge_requests/4","author":{"username":"bo"},\
    "source_branch":"fix/y","state":"opened","draft":true,"head_pipeline":{"status":"failed"}}]';;
      *"merge_requests?source_branch=feat%2Fgl"*) echo '[{"iid":9,"title":"GL","web_url":"u","author":{"username":"bo"},"source_branch":"feat/gl","state":"merged"}]';;
      *"merge_requests/9"*) echo '{"iid":9,"title":"GL","web_url":"u","author":{"username":"bo"},"source_branch":"feat/gl","state":"merged",\
    "head_pipeline":{"status":"running"}}';;
      "auth status") echo "✓ Logged in to gitlab.example.com as ada (/x/config.yml)" >&2;;
      *"issues?state=opened"*) echo '[{"iid":2,"title":"Bug","description":null,"web_url":"w","labels":["p1"],"assignees":[{"username":"bo"}],"state":"opened"}]';;
      *) echo "unexpected: $*" >&2; exit 1;;
    esac
    """.write(toFile: script, atomically: true, encoding: .utf8)
    chmod(script, 0o755)
    if getenv("KELP_GLAB") == nil { setenv("KELP_GLAB", script, 1) }
    return log
}()

@Test func onGitLabAPullRequestIsAMergeRequestNotAGhCall() async throws {
    let log = fakeGlab
    let r = try await rig()
    defer { r.d.stop() }
    let wt = try await workspace(r, "feat/mr")
    // origin looks like GitLab; pushes go to a bare repository here.
    let bare = tmp().path
    try Git.run(["init", "-q", "--bare", bare], cwd: bare, remotes: .none)
    try Git.run(["remote", "add", "origin", "git@gitlab.example.com:g/r.git"], cwd: wt.path, remotes: .none)
    try Git.run(["config", "url.\(bare).pushInsteadOf", "git@gitlab.example.com:g/r.git"], cwd: wt.path, remotes: .none)
    try "x\n".write(toFile: wt.path + "/x.txt", atomically: true, encoding: .utf8)
    try Git.run(["add", "x.txt"], cwd: wt.path, remotes: .none)
    try Git.run(["commit", "-qm", "Add x"], cwd: wt.path, remotes: .none)
    let made = try await r.c.call(
        "github.pr-create", .obj(["worktreeId": .string(wt.id), "title": "Add x", "body": "Why", "draft": true]))
    #expect(made["url"]?.string == "https://gitlab.example.com/g/r/-/merge_requests/12")
    let sent = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
    #expect(
        sent.contains("source_branch=feat/mr") && sent.contains("title=Draft: Add x")
            && sent.contains("target_branch=main"))
    _ = try await r.c.call("github.pr-merge", .obj(["worktreeId": .string(wt.id)]))
    #expect(
        ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").contains(
            "merge_requests/12/merge --raw-field squash=true"))
    // The gh log is every test's (they run at once): this one's PR is the one titled "Add x".
    #expect(!calls().contains { ($0.hasPrefix("pr create") && $0.contains("Add x")) || $0.hasPrefix("pr merge 12") })   // gh, which can't talk to GitLab, was never asked
}

@Test func aWorkspaceLinksToItsProjectsPagesFromOrigin() async throws {
    let r = try await rig()
    defer { r.d.stop() }
    let wt = try await workspace(r, "feat/pages")
    #expect(try await r.c.call("git.webPages", .obj(["worktreeId": .string(wt.id)])) == .null)   // no origin: nothing to open
    try Git.run(["remote", "add", "origin", "git@gitlab.example.com:g/r.git"], cwd: wt.path, remotes: .none)
    let pages = try await r.c.call("git.webPages", .obj(["worktreeId": .string(wt.id)]))
    #expect(pages["forge"]?.string == "gitlab" && pages["ci"]?.string == "https://gitlab.example.com/g/r/-/pipelines")
}

/// On GitLab the lists come from its API through glab: merge requests with their pipeline, issues, mine only when asked,
/// and a branch's newest merge request with its pipeline read in full.
@Test func onGitLabListsComeFromItsAPI() async throws {
    let log = fakeGlab
    let r = try await rig()
    defer { r.d.stop() }
    let wt = try await workspace(r, "feat/gl")
    try Git.run(["remote", "add", "origin", "git@gitlab.example.com:g/r.git"], cwd: r.repo.path, remotes: .none)
    let prs = try await r.c.call("github.prs", .obj(["repoId": .string(r.repo.id), "filter": "mine"])).array ?? []
    #expect(
        prs.count == 1 && prs[0]["number"]?.int == 4 && prs[0]["isDraft"]?.bool == true
            && prs[0]["state"]?.string == "OPEN")
    #expect(prs[0]["checks"]?["failed"]?.int == 1)
    let issues =
        try await r.c.call("github.issues", .obj(["repoId": .string(r.repo.id), "filter": "mine"])).array ?? []
    #expect(issues.first?["labels"]?.array?.first?.string == "p1" && issues.first?["state"]?.string == "OPEN")
    let sent = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
    #expect(sent.contains("scope=created_by_me") && sent.contains("scope=assigned_to_me"))
    let branch = try await r.c.call("github.branchPR", .obj(["worktreeId": .string(wt.id)]))
    #expect(branch["number"]?.int == 9 && branch["state"]?.string == "MERGED" && branch["checks"]?["pending"]?.int == 1)
}

/// On GitHub a pull request is opened and merged through gh: pushed first, titled from its commits, draft when asked,
/// its URL the last line gh prints; merged by number in the method asked for.
@Test func onGitHubAPullRequestIsOpenedAndMergedThroughGh() async throws {
    let r = try await rig()
    defer { r.d.stop() }
    let wt = try await workspace(r, "feat/gh")
    let bare = tmp().path
    try Git.run(["init", "-q", "--bare", bare], cwd: bare, remotes: .none)
    try Git.run(["remote", "add", "origin", bare], cwd: wt.path, remotes: .none)
    try "x\n".write(toFile: wt.path + "/x.txt", atomically: true, encoding: .utf8)
    try Git.run(["add", "x.txt"], cwd: wt.path, remotes: .none)
    try Git.run(["commit", "-qm", "Add gh"], cwd: wt.path, remotes: .none)
    let made = try await r.c.call("github.pr-create", .obj(["worktreeId": .string(wt.id), "draft": true]))
    #expect(made["url"]?.string == "https://github.com/o/r/pull/8")
    #expect(Git.branchExists(bare, "feat/gh", remotes: .none))   // pushed before gh was asked
    let create = calls().last { $0.hasPrefix("pr create") } ?? ""
    #expect(create.contains("--title Add gh") && create.contains("--base main") && create.hasSuffix("--draft"))
    _ = try await r.c.call("github.pr-merge", .obj(["worktreeId": .string(wt.id), "pr": 8, "method": "rebase"]))
    #expect(calls().contains("pr merge 8 --rebase"))   // the GitLab test's merge is #12, through glab
    // Only the commit that was on screen is merged: a PR that moved on says so instead.
    _ = try await r.c.call("github.pr-merge", .obj(["worktreeId": .string(wt.id), "pr": 8, "head": "abc"]))
    #expect(calls().contains("pr merge 8 --squash --match-head-commit abc"))
    await #expect {
        _ = try await r.c.call("github.pr-merge", .obj(["worktreeId": .string(wt.id), "pr": 8, "head": "old"]))
    } throws: {
        "\($0)".contains("new commits since you looked")
    }
}
