import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// What can be done to a pull request from Kelp, for its tab and the list's menu: its folder (made when needed), an
/// agent to review it, fix its checks or answer its reviewers, and the merge.
@MainActor
struct PRWork {
    let app: AppModel, repoId: String, pr: GitHub.PullRequest

    /// The PR's folder: on its own branch, or on `pr-<n>` when another branch took that name
    /// (`Git.fetchPullRequest`). It is the project's own checkout only while that checkout has the PR's branch out.
    var worktree: Worktree? {
        let main = app.repo(repoId)?.path, base = app.repo(repoId)?.baseBranch
        return app.worktrees.first {
            $0.repoId == repoId && !$0.archived
                && ($0.branch == "pr-\(pr.number)"
                    || ($0.branch == pr.headRefName && ($0.path != main || pr.headRefName != base)))
        }
    }

    /// The PR's folder, made on the PR's head when it has none (as New Group on Branch… › Pull Request makes it). The
    /// .kelp.yaml setup is asked about there too.
    func folder() async -> Worktree? {
        if let worktree { return worktree }
        // The list marks the PR once the workspace comes, because it follows the project's workspaces.
        guard let made = await app.call(WorktreeCreate(repoId: repoId, branch: pr.headRefName, pr: pr.number)) else {
            return nil
        }
        if made.setupNeedsTrust == true {
            Task { await KelpFile(app: app).setup(made.worktree.id, pullRequest: pr.number) }
        }
        return made.worktree
    }

    func openFolder() {
        Task { if let wt = await folder() { app.workbench.show(workspace: wt.id) } }
    }

    /// Shows the PR's changes against its base in its folder: the diff with Viewed, comments and Review with.
    func showFiles() {
        Task {
            guard let wt = await folder() else { return }
            app.workbench.open(TabURI.diff(wt.id, source: .branch), workspace: wt.id)
        }
    }

    /// The default agent reads the PR's changes in its folder and leaves its findings on their lines, which the diff
    /// beside it shows.
    func review(base: String) {
        Task {
            guard let wt = await folder() else { return }
            let range = "origin/\(base)...HEAD"
            let vars = [
                "scope": String(localized: "pull request #\(pr.number)'s changes since \(base)"),
                "command": "git diff " + ShellQuote.word(range)
            ]
            guard let prompt = await app.call(RecipeRender(id: wt.id, name: "reviewWith", vars: vars)) else { return }
            let title = String(localized: "Review: #\(pr.number)")
            await start(prompt, in: wt, draft: false, title: title, role: .reviewer)
            app.workbench.open(TabURI.diff(wt.id, source: .branch), split: .right, workspace: wt.id, focus: false)
        }
    }

    /// Hands the first failing check's log to the agent in the PR's folder to fix.
    func fixChecks() {
        Task {
            guard let wt = await folder() else { return }
            let checks = await app.call(GitHubChecks(repoId: repoId, pr: pr.number)) ?? []
            guard let check = checks.first(where: { $0.bucket == "fail" }) else {
                Banner.show(String(localized: "No failing check on #\(pr.number) now."))
                return
            }
            var log: String?
            if let run = check.runId { log = await app.call(GitHubFailedLog(repoId: repoId, runId: run)) }
            await hand("fixCI", ["check": check.name, "error": log ?? check.link], to: wt)
        }
    }

    /// Hands what reviewers asked for to the agent in the PR's folder to address.
    func answerReviews() {
        Task {
            guard let comments = await app.call(GitHubReviewComments(repoId: repoId, pr: pr.number)) else { return }
            guard !comments.isEmpty else {
                Banner.show(String(localized: "No review comments on #\(pr.number)."))
                return
            }
            guard let wt = await folder() else { return }
            await hand("review", ["comments": TasksViewController.forAgent(comments)], to: wt)
        }
    }

    /// Renders a recipe with someone else's words in it (a log, comments). It is typed into the folder's agent for the
    /// user to send (`FileActions.pickAgent`), or, when the folder has no agent, a new agent starts with it as a draft.
    private func hand(_ recipe: String, _ vars: [String: String], to wt: Worktree) async {
        guard let text = await app.call(RecipeRender(id: wt.id, name: recipe, vars: vars)) else { return }
        guard !FileActions(app).agents(in: wt.id).isEmpty else {
            return await start(text, in: wt, draft: true, title: nil)
        }
        guard let agent = await FileActions(app).pickAgent(in: wt.id) else { return }
        await app.call(SessionSend(id: agent.id, text: text, enter: false))
        app.workbench.focus(session: agent.id)
    }

    private func start(_ prompt: String, in wt: Worktree, draft: Bool, title: String?, role: SessionRole? = nil) async {
        guard
            let session = await app.call(
                app.workbench.sized(
                    SessionCreate(
                        worktreeId: wt.id, agent: app.catalog.defaultAgent, prompt: prompt, title: title,
                        draft: draft ? true : nil
                    ).started(as: role)))
        else { return }
        app.upsert(session)
        app.workbench.focus(session: session.id)
    }

    /// GitHub's three ways to merge, as a menu. The commit on screen is the one that lands (`--match-head-commit`).
    func mergeMenu(done: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        for (title, method) in [
            (String(localized: "Squash and Merge"), "squash"), (String(localized: "Create a Merge Commit"), "merge"),
            (String(localized: "Rebase and Merge"), "rebase")
        ] {
            menu.add(title) { merge(method: method, title: title, done: done) }
        }
        return menu
    }

    private func merge(method: String, title: String, done: @escaping () -> Void) {
        Task {
            guard await confirm(String(localized: "\(title) #\(pr.number)?"), action: String(localized: "Merge")) else {
                return
            }
            // gh needs a checkout of the project: the PR's own folder if it has one.
            guard let wid = worktree?.id ?? app.worktrees.first(where: { $0.repoId == repoId })?.id else {
                NSSound.beep()
                return
            }
            let merge = GitHubPRMerge(worktreeId: wid, pr: pr.number, method: method, head: pr.headRefOid)
            if await app.call(merge) != nil {
                Banner.show(String(localized: "Merged #\(pr.number)"))
                app.watchAgain(.prs, repoId)   // the open PRs are read again, and the list follows them
                done()
            }
        }
    }

    /// Why GitHub won't merge the PR yet, in words; nil when nothing stands in the way (or GitHub hasn't said).
    static func mergeBlock(_ pull: GitHub.PullRequest) -> String? {
        switch pull.mergeState {
        case "DIRTY": String(localized: "It conflicts with the base branch: resolve the conflicts first.")
        case "BEHIND": String(localized: "The base branch moved on: update this branch first.")
        case "DRAFT": String(localized: "It's a draft: mark it ready for review first.")
        case "UNSTABLE": String(localized: "Some checks failed, though GitHub lets it merge.")
        case "BLOCKED": blocked(pull)
        default: nil
        }
    }

    /// GitHub says only BLOCKED, so this names the review or the checks when they are what it waits for.
    private static func blocked(_ pull: GitHub.PullRequest) -> String {
        if pull.reviewDecision == "CHANGES_REQUESTED" { return String(localized: "A reviewer asked for changes.") }
        if pull.reviewDecision == "REVIEW_REQUIRED" { return String(localized: "It needs an approving review.") }
        if pull.checks.failed > 0 { return String(localized: "Required checks failed.") }
        if pull.checks.pending > 0 { return String(localized: "Required checks are still running.") }
        return String(localized: "The repository's rules block it.")
    }

    /// The one thing to do next, by what stands in the PR's way and whose PR it is.
    enum Next: Equatable { case fix, answer, review, merge, wait }
    static func next(_ pr: GitHub.PullRequest, mine: Bool) -> Next {
        if pr.state != "OPEN" { return .wait }
        if pr.checks.failed > 0 && mine { return .fix }
        if pr.reviewDecision == "CHANGES_REQUESTED" && mine { return .answer }
        if !mine && pr.reviewDecision != "APPROVED" { return .review }
        if pr.isDraft || pr.mergeState == "DIRTY" || pr.mergeState == "BEHIND" || pr.checks.pending > 0 { return .wait }
        return pr.checks.failed > 0 ? .fix : .merge
    }
}

/// Who `gh` is signed in as, which says whose PRs are "yours" and whose review is asked for. It is asked once a run.
@MainActor
enum Viewer {
    private static var login: String?
    static func get(_ app: AppModel) async -> String? {
        if let login { return login }
        // When not signed in, it's asked again next time, and the list says why.
        login = await app.quiet(GitHubStatus())?.user
        return login
    }
}
