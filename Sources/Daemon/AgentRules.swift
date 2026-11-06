import Foundation
import Core

/// What an agent's program may reach, beside `Daemon.allow`, which asks these.
enum AgentRules {
    /// The methods an agent's program, or one kelpd runs (an extension's, a git hook), may call at all; each still has its
    /// own rules (`actsOn`, `inWorkspace`, …). What agents use (their skills, hooks and `kelp` commands) and what reads.
    /// Everything else is the user's (commits, pushes, PRs, CI, trackers, credentials, projects, routines, scripts, the
    /// daemon itself): a new method is closed to agents until it's put here.
    static let methods: Set<String> = [
        // reading
        "agents.versions", "ci.failures", "ci.fullLog", "ci.jobs", "ci.log", "ci.runs", "comment.list", "daemon.info", "ping",
        "extension.library", "files.fetch", "files.ignored", "files.list", "files.read", "files.readRemote", "files.search",
        "git.authorAvatar", "git.branches", "git.commitDetails", "git.commitFiles", "git.diff", "git.graph", "git.hunk",
        "git.lineStats", "git.log", "git.remote", "git.status", "git.unsynced", "git.webPages", "git.webURL",
        "github.branchPR", "github.checks", "github.failedLog", "github.forge", "github.issues", "github.projectItems",
        "github.projects", "github.prs", "github.reviewComments", "github.status", "gitlab.status", "bitbucket.status",
        "jira.issues", "jira.status", "jira.transitions", "linear.issues", "linear.states", "linear.status", "linear.teams",
        "history.list", "host.stats", "ports.list", "process.which", "recipe.render", "remote.listFolders", "repo.icon",
        "repo.list", "repo.worktreeSizes", "routine.list", "run.detect", "scripts.list", "session.busy", "session.commands",
        "session.context", "session.contextParts", "session.contextWindow", "session.lastReply", "session.list",
        "session.read", "session.subagentJournal", "session.subagentSteps", "session.trail", "session.turns",
        "session.usage", "session.why", "settings.get", "skills.browser", "state.get", "tmux.list", "ui.state",
        "usage.agents", "usage.get", "vm.detail", "vm.list", "worktree.dirty", "worktree.list", "worktree.unmerged",
        "client.events", "watch.start", "watch.stop",
        // its own sessions and those it started (`actsOn`, named ids), its hooks and reports
        "session.attach", "session.detach", "session.resize", "session.create", "session.send", "session.write",
        "session.kill", "session.restart", "session.rename", "session.markRead", "session.markUnread", "session.recap",
        "session.handoff", "session.continueAt", "session.turn", "session.turnUndo", "session.turnRedo", "session.hook",
        "session.report", "session.permissionWait", "pane.report_agent", "usage.report", "comment.add", "comment.send",
        // the IDE, in its own workspaces (`inWorkspace`), and what its skills do
        "ui.open", "ui.command", "ui.browser", "ports.stop", "settings.set", "extension.fetch",
        "workspace.create", "worktree.create", "worktree.note", "worktree.archive", "worktree.remove",
        "vm.connect", "vm.screen", "vm.type", "vm.control"
    ]
}

extension Sessions {
    /// The sessions a call names, in any field (an `id`, a `session`, a `parent`, a list of them, a struct's or an
    /// enum's in turn): what an agent's call may reach is decided by what it names, not by each method remembering to
    /// say. Free-form JSON (`JSONValue`: a setting's value, a command's args) and bytes name none.
    func named(by m: Any) throws -> [String] {
        func strings(_ v: Any, depth: Int) -> [String] {
            if let s = v as? String { return [s] }
            guard depth < 6, !(v is JSONValue), !(v is Data) else { return [] }
            return Mirror(reflecting: v).children.flatMap { strings($0.value, depth: depth + 1) }
        }
        return try strings(m, depth: 0).filter { UUID(uuidString: $0) != nil }.filter { try store.session($0) != nil }
    }

    /// Whether `w` is the workspace of `own` or of one that started it, one they made, or one a session it started works
    /// in (which it could start there only for one of those): an agent works there only.
    func works(_ own: String, in w: String) throws -> Bool {
        let line = try lineage(own)
        if line.contains(where: { $0.worktreeId == w }) { return true }
        if let maker = made.withLock({ $0[w] }), line.contains(where: { $0.id == maker }) { return true }
        return try store.sessions().contains { s in try s.worktreeId == w && lineage(s.id).contains { $0.id == own } }
    }

    /// The sessions removing `e` ends: those of the workspace, or of every workspace of the project.
    func ending(_ e: Ending) throws -> [String] {
        let ids: Set<String> = switch e {
        case .workspace(let w): [w]
        case .project(let r): Set(try store.worktrees(repo: r).map(\.id))
        }
        return try store.sessions().filter { ids.contains($0.worktreeId ?? "") }.map(\.id)
    }
}
