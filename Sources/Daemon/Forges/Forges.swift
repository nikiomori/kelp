import Core
import Foundation
import Integrations
import os

/// What the daemon keeps for the forges and trackers. It holds GitHub's pull requests by branch (which every sidebar
/// row asks for), the clones that are running, and the clients for Linear, Jira and Bitbucket. Their credentials are in
/// the keychain, read off the cooperative pool, because a locked login keychain can keep a caller waiting.
final class Forges: Sendable {
    let offloads: Slots
    let prCache = OSAllocatedUnfairLock<[String: (at: Date, value: GitHub.PullRequest?)]>(initialState: [:])   // "path@branch" → its PR (github.branchPR)
    /// Commit authors' avatars by email (git.authorAvatar). Each author is asked for once, and a miss is asked again
    /// after ten minutes.
    let avatars = OSAllocatedUnfairLock<[String: (at: Date, value: Data?)]>(initialState: [:])
    /// Running clones by the id the app gave them, for `repo.cloneCancel`.
    let clones = Clones()
    final class Clones: Sendable {
        private let running = OSAllocatedUnfairLock<[String: Process]>(initialState: [:])
        func set(_ id: String, _ process: Process?) { running.withLock { $0[id] = process } }
        /// Cancels a running clone, but not one still starting, because `interrupt` raises before `run` and that would
        /// take the daemon down.
        func cancel(_ id: String) { running.withLock { $0[id] }.map(Self.interrupt) }
        func cancelAll() { running.withLock { Array($0.values) }.forEach(Self.interrupt) }
        private static func interrupt(_ process: Process) { if process.isRunning { process.interrupt() } }
    }

    let store: Store, clients: Clients, remotes: Remotes

    init(offloads: Slots, store: Store, clients: Clients, remotes: Remotes) {
        self.offloads = offloads
        self.store = store
        self.clients = clients
        self.remotes = remotes
    }

    func notify(_ event: some RPCEvent, to only: Set<Int>? = nil) { clients.notify(event, to: only) }

    static let linearKeyAccount = "linear-api-key"

    /// The Linear client, or nil without an account. A keychain that can't be read now (because it is locked) throws,
    /// with the reason.
    var linear: LinearClient? {
        get throws { try Keychain.find(Self.linearKeyAccount).map(LinearClient.init(apiKey:)) }
    }

    /// Jira / Bitbucket credentials: one JSON blob each in the keychain.
    static let jiraAccount = "jira", bitbucketAccount = "bitbucket"
    var jira: JiraClient? {
        get throws {
            guard let secret = try Keychain.find(Self.jiraAccount),
                let fields = Log.store.attempt(
                    "reading Jira's keychain item",
                    { try JSONDecoder().decode([String: String].self, from: Data(secret.utf8)) }),
                let site = fields["site"], let email = fields["email"], let token = fields["token"]
            else { return nil }
            return JiraClient(site: site, email: email, token: token)
        }
    }
    var bitbucket: BitbucketClient? {
        get throws {
            guard let secret = try Keychain.find(Self.bitbucketAccount),
                let fields = Log.store.attempt(
                    "reading Bitbucket's keychain item",
                    { try JSONDecoder().decode([String: String].self, from: Data(secret.utf8)) }),
                let user = fields["user"], let token = fields["token"]
            else { return nil }
            return BitbucketClient(user: user, token: token)
        }
    }
    /// These read the keychain off the cooperative pool, because a locked login keychain can keep a caller waiting.
    /// Each returns nil when there is no account. A keychain that can't be read throws, so the failure isn't taken for
    /// "add credentials".
    func linearClient() async throws -> LinearClient? { try await offloads.run { [self] in try linear } }
    func jiraClient() async throws -> JiraClient? { try await offloads.run { [self] in try jira } }
    func bitbucketClient() async throws -> BitbucketClient? { try await offloads.run { [self] in try bitbucket } }
    /// Reads a client for work that runs on its own (an issue moved along with its PR). A keychain failure is logged,
    /// and the result is nil.
    private func client<C>(_ name: String, _ read: () async throws -> C?) async -> C? {
        do { return try await read() } catch {
            Log.rpc.error("reading \(name, privacy: .public)'s keychain item: \(error)")
            return nil
        }
    }
    /// Saves a secret in the keychain, off the pool as well. An empty value removes the account.
    func keepSecret(_ value: String, account: String) async throws {
        try await offloads.run {
            if value.isEmpty { Keychain.delete(account) } else { try Keychain.set(value, account: account) }
        }
    }

    /// Moves the Jira issue linked to a worktree ("ENG-12") along with the PR, like Linear.
    func moveJira(_ worktree: Worktree, toName hint: String, category: String) async {
        guard let client = await client("Jira", jiraClient),
            worktree.issue.range(of: #"^[A-Z][A-Z0-9]+-\d+$"#, options: .regularExpression) != nil,
            worktree.linearIssueId.isEmpty
        else { return }
        do { try await client.move(key: worktree.issue, toName: hint, category: category) } catch {
            Log.rpc.notice(
                "Jira issue \(worktree.issue, privacy: .public) didn't move to \(hint, privacy: .public): \(error)")
        }
    }

    /// Moves the linked Linear issue to a kind of workflow state. It quietly does nothing without a key or a link.
    func moveLinear(_ worktree: Worktree, to kind: LinearClient.StateKind) async {
        guard !worktree.linearIssueId.isEmpty, let client = await client("Linear", linearClient) else { return }
        do {
            // Limit: the team is found through the user's own issues. Query the issue by id if tasks assigned to
            // others need moving.
            guard let issue = try await client.myIssues().first(where: { $0.id == worktree.linearIssueId }),
                let st = LinearClient.stateFor(kind: kind, in: try await client.workflowStates(teamId: issue.team.id))
            else { return }
            try await client.setState(issueId: worktree.linearIssueId, stateId: st.id)
        } catch {
            Log.rpc.notice("Linear issue \(worktree.linearIssueId, privacy: .public) didn't move: \(error)")
        }
    }
}
