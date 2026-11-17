import AgentData
import Agents
import Core
import Foundation
import GitKit
import Integrations

extension TaskFromIssue: AsyncHandled {
    func handle(_ work: ForgeWork) async throws -> Result {
        guard let repo = try work.workspaces.store.repo(repoId) else { throw RPCError.noProject(repoId) }
        let body = body ?? "", url = url ?? ""
        var branch =
            branch.flatMap { $0.isEmpty ? nil : $0 }
            ?? IssueRef.branchName(ref.hasPrefix("#") ? String(ref.dropFirst()) : ref.lowercased(), title: title)
        let prefix = branchPrefix ?? work.workspaces.sessions.branchPrefix
        if !prefix.isEmpty, !branch.hasPrefix(prefix) { branch = prefix + branch }
        let unique = try await work.offloads.run { [branch] in
            var unique = branch, number = 2
            while Git.branchExists(repo.path, unique, remotes: work.workspaces.remotes) {
                unique = "\(branch)-\(number)"
                number += 1
            }
            return unique
        }
        let created = try await work.offloads.run {
            try work.workspaces.createBranchWorkspace(
                in: repo, WorktreeCreate(repoId: repo.id, branch: unique, note: "\(ref) \(title)", tabs: false))
        }
        // Writing the record, reading the repo's config and starting the agent's PTY touch the disk and start a
        // process, so they go through `offload` like the rest.
        let (worktree, session) = try await work.offloads.run { () throws -> (Worktree, Session) in
            guard
                let updated = try work.workspaces.store.update(
                    Worktree.self, created.worktree.id,
                    {
                        $0.issue = ref
                        $0.issueURL = url
                        $0.linearIssueId = linearId ?? ""
                    })
            else { throw RPCError.internalError("worktree vanished") }
            // its issueCommand / recipes only once the user trusts the file
            let cfg = work.workspaces.trustedConfig(repo.path)
            let vars = ["title": title, "body": body, "url": url, "ref": ref, "branch": unique]
            var text =
                cfg.issueCommand.map { Recipes.fill($0, Recipes.framed(vars)) }
                ?? Recipes.render("issue", config: cfg, vars: vars)
            if let extra = prompt, !extra.isEmpty { text += "\n\n" + extra }
            var launch = Sessions.Launch()
            // Typed, not sent, unless asked: the issue's text is whoever filed it, not the user (it could tell the agent anything).
            launch.model = model
            launch.effort = effort
            launch.profile = profile
            launch.draft = draft != false
            launch.openURLs = openURLs == true
            (launch.cols, launch.rows) = Sessions.Launch.size(cols: cols, rows: rows)
            launch.prompt = text
            launch.title = "\(ref) \(title)".prefix(48).description
            return (
                updated,
                try work.workspaces.sessions.spawn(
                    cwd: updated.path,
                    manifest: work.workspaces.sessions.setup.manifest(agent ?? Session.claudeAgent, command: nil),
                    worktreeId: updated.id, launch)
            )
        }
        await work.forges.moveLinear(worktree, to: .inProgress)
        await work.forges.moveJira(worktree, toName: "progress", category: "indeterminate")
        work.workspaces.notify(ChangedEvent.worktree)
        // An untrusted .kelp.yaml's setup didn't run: said, as worktree.create says it, so the caller can ask.
        return Result(worktree: worktree, session: session, setupNeedsTrust: created.setupNeedsTrust == true)
    }
}
