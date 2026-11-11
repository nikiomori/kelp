import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// What can be done to a run, for the panel's menus and the bar over a job. `changed`: the runs are worth reading again.
@MainActor
struct CIActions {
    let app: AppModel, worktree: String, changed: () -> Void

    func rerunFailed(_ run: Int) {
        act(CIRerun(worktreeId: worktree, run: run), said: String(localized: "Re-running the failed jobs"))
    }
    func rerunAll(_ run: Int) {
        act(CIRerunAll(worktreeId: worktree, run: run), said: String(localized: "Re-running the run"))
    }
    func rerunJob(_ job: Int) {
        act(CIRerunJob(worktreeId: worktree, job: job), said: String(localized: "Re-running the job"))
    }

    /// A cancelled run can't be taken back, only started again.
    func cancel(_ run: CIRuns.Run) {
        Task {
            guard
                await confirm(
                    String(localized: "Cancel “\(run.title)”?"),
                    detail: String(localized: "What's running stops now. You can start the run again."),
                    action: String(localized: "Cancel Run"))
            else { return }
            act(CIRunCancel(worktreeId: worktree, run: run.id), said: String(localized: "Cancelling the run"))
        }
    }

    /// The commit's changes here; on the forge's site if this clone hasn't fetched it.
    func showCommit(_ run: CIRuns.Run) {
        guard let sha = run.sha else { return }
        Task {
            if await app.tryCall(GitCommitDetails(id: worktree, commit: sha)).value != nil {
                app.workbench.open(TabURI.diff(worktree, commit: sha))
            } else if let page = run.commitURL {
                Forge.open(page)
            }
        }
    }

    /// What broke in this job, typed into the workspace's agent for the user to send.
    func fix(_ job: CIRuns.Job) {
        guard hasAgent else { return }
        Task {
            // the banner says why
            guard let report = await app.call(CIFailures(worktreeId: worktree, job: job.id)) else { return }
            GitFix(app).send("fixCI", worktree: worktree, vars: ["check": job.name, "error": report.forAgent])
        }
    }

    /// False, said in a banner: nobody to ask.
    var hasAgent: Bool {
        if FileActions(app).targetAgent != nil { return true }
        Banner.show(String(localized: "No agent on this screen. Start one with ⌥⌘T, then ask again."), style: .error)
        return false
    }

    private func act<M: RPCMethod>(_ method: M, said: String) {
        Task {
            guard await app.call(method) != nil else { return }
            Banner.show(said)
            changed()
        }
    }
}
