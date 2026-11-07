import Core
import Foundation
import Integrations
import os

/// What the daemon keeps for the forges and trackers: GitHub's pull requests by branch (asked by every sidebar row), the
/// clones running, and Linear, Jira and Bitbucket, whose credentials are in the keychain (read off the cooperative pool:
/// a locked login keychain can keep a caller waiting).
final class Forges: Sendable {
    let offloads: Slots
    let prCache = OSAllocatedUnfairLock<[String: (at: Date, value: GitHub.PullRequest?)]>(initialState: [:])   // "path@branch" → its PR (github.branchPR)
    /// Commit authors' avatars by email (git.authorAvatar): one ask per author, a miss asked again after ten minutes.
    let avatars = OSAllocatedUnfairLock<[String: (at: Date, value: Data?)]>(initialState: [:])
    /// Running clones by the id the app gave them, for `repo.cloneCancel`.
    let clones = Clones()
    final class Clones: Sendable {
        private let running = OSAllocatedUnfairLock<[String: Process]>(initialState: [:])
        func set(_ id: String, _ p: Process?) { running.withLock { $0[id] = p } }
        /// Not one still starting: `interrupt` raises before `run`, and that would take the daemon down.
        func cancel(_ id: String) { running.withLock { $0[id] }.map(Self.interrupt) }
        func cancelAll() { running.withLock { Array($0.values) }.forEach(Self.interrupt) }
        private static func interrupt(_ p: Process) { if p.isRunning { p.interrupt() } }
    }

    let store: Store, clients: Clients, remotes: Remotes

    init(offloads: Slots, store: Store, clients: Clients, remotes: Remotes) {
        self.offloads = offloads
        self.store = store
        self.clients = clients
        self.remotes = remotes
    }

    func notify(_ e: some RPCEvent, to only: Set<Int>? = nil) { clients.notify(e, to: only) }

    static let linearKeyAccount = "linear-api-key"

    var linear: LinearClient? { Keychain.get(Self.linearKeyAccount).map(LinearClient.init(apiKey:)) }

    /// Jira / Bitbucket credentials: one JSON blob each in the keychain.
    static let jiraAccount = "jira", bitbucketAccount = "bitbucket"
    var jira: JiraClient? {
        guard let s = Keychain.get(Self.jiraAccount),
            let v = Log.store.attempt(
                "reading Jira's keychain item", { try JSONDecoder().decode([String: String].self, from: Data(s.utf8)) }),
            let site = v["site"], let email = v["email"], let token = v["token"]
        else { return nil }
        return JiraClient(site: site, email: email, token: token)
    }
    var bitbucket: BitbucketClient? {
        guard let s = Keychain.get(Self.bitbucketAccount),
            let v = Log.store.attempt(
                "reading Bitbucket's keychain item",
                { try JSONDecoder().decode([String: String].self, from: Data(s.utf8)) }),
            let u = v["user"], let t = v["token"]
        else { return nil }
        return BitbucketClient(user: u, token: t)
    }
    /// The keychain can keep a caller waiting (a locked login keychain): these read it off the cooperative pool.
    func linearClient() async -> LinearClient? { try? await offloads.run { [self] in linear } }
    func jiraClient() async -> JiraClient? { try? await offloads.run { [self] in jira } }
    func bitbucketClient() async -> BitbucketClient? { try? await offloads.run { [self] in bitbucket } }
    /// Saved there, off the pool as well; an empty one removes the account.
    func keepSecret(_ value: String, account: String) async throws {
        try await offloads.run {
            if value.isEmpty { Keychain.delete(account) } else { try Keychain.set(value, account: account) }
        }
    }

    /// Jira issues linked to a worktree ("ENG-12") move along with the PR, like Linear.
    func moveJira(_ w: Worktree, toName hint: String, category: String) async {
        guard let j = await jiraClient(),
            w.issue.range(of: #"^[A-Z][A-Z0-9]+-\d+$"#, options: .regularExpression) != nil,
            w.linearIssueId.isEmpty
        else { return }
        do { try await j.move(key: w.issue, toName: hint, category: category) } catch {
            Log.rpc.notice("Jira issue \(w.issue, privacy: .public) didn't move to \(hint, privacy: .public): \(error)")
        }
    }

    /// Move a linked Linear issue to a workflow state kind; quiet no-op without a key or link.
    func moveLinear(_ w: Worktree, to kind: LinearClient.StateKind) async {
        guard !w.linearIssueId.isEmpty, let l = await linearClient(),
            // Limit: finds the team via my issues; query the issue by id if tasks assigned to others need moving
            let issue = try? await l.myIssues().first(where: { $0.id == w.linearIssueId }) ?? nil,
            let states = try? await l.workflowStates(teamId: issue.team.id),
            let st = LinearClient.stateFor(kind: kind, in: states)
        else { return }
        do { try await l.setState(issueId: w.linearIssueId, stateId: st.id) } catch {
            Log.rpc.notice("Linear issue \(w.linearIssueId, privacy: .public) didn't move: \(error)")
        }
    }
}
