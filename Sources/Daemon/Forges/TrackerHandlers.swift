import Core
import Foundation
import Integrations

// Linear and Jira: their keys, issues, teams, states and transitions.

extension Forges {
    /// What `read` answers, nil when the service turned the credentials down; any other failure is thrown, its reason said.
    static func unlessRefused<T>(_ read: () async throws -> T) async throws -> T? {
        do { return try await read() } catch let error as IntegrationError where error.refused { return nil }
    }
}

extension LinearSetKey: AsyncHandled {
    func handle(_ forges: Forges) async throws -> LinearUser? {
        if key.isEmpty {
            try await forges.keepSecret("", account: Forges.linearKeyAccount)
            return nil
        }
        let me = try await LinearClient(apiKey: key).viewer()   // validate before saving
        try await forges.keepSecret(key, account: Forges.linearKeyAccount)
        return me
    }
}
extension LinearStatus: AsyncHandled {
    // whether Linear is connected, not what's in it: its issues and teams are read with the user's key, which
    // an agent's own shell can't read
    static let agents = AgentAccess.reads
    func handle(_ forges: Forges) async throws -> Result {
        guard let linear = try await forges.linearClient() else { return Result(connected: false) }
        // A key Linear turns down is no connection; Linear not answering (offline, a 5xx) is said, not read as one.
        guard let me = try await Forges.unlessRefused({ try await linear.viewer() }) else {
            return Result(connected: false)
        }
        return Result(connected: true, name: me.name)
    }
}
extension LinearIssues: AsyncHandled {
    func handle(_ forges: Forges) async throws -> [LinearIssue] {
        guard let linear = try await forges.linearClient() else {
            throw RPCError.invalidParams("Linear is not connected (Settings › Integrations)")
        }
        if let teamId { return try await linear.teamIssues(teamId: teamId) }
        return try await linear.myIssues()
    }
}
extension LinearTeams: AsyncHandled {
    func handle(_ forges: Forges) async throws -> [LinearTeam] {
        guard let linear = try await forges.linearClient() else { return [] }
        return try await linear.teams()
    }
}
extension LinearStates: AsyncHandled {
    func handle(_ forges: Forges) async throws -> [LinearState] {
        guard let linear = try await forges.linearClient() else { return [] }
        return try await linear.workflowStates(teamId: teamId)
    }
}
extension LinearSetState: AsyncHandled {
    func handle(_ forges: Forges) async throws -> Done {
        guard let linear = try await forges.linearClient() else {
            throw RPCError.invalidParams("Linear is not connected")
        }
        try await linear.setState(issueId: issueId, stateId: stateId)
        return Done()
    }
}

extension JiraSetCredentials: AsyncHandled {
    func handle(_ forges: Forges) async throws -> Account? {
        if token.isEmpty {
            try await forges.keepSecret("", account: Forges.jiraAccount)
            return nil
        }
        let name = try await JiraClient(site: site, email: email, token: token).myself()   // validate before saving
        try await forges.keepSecret(
            String(decoding: try JSONEncoder().encode(["site": site, "email": email, "token": token]), as: UTF8.self),
            account: Forges.jiraAccount)
        return Account(name: name)
    }
}
extension JiraStatus: AsyncHandled {
    // whether Jira is connected, not what's in it: its issues and transitions are read with the user's key,
    // which an agent's own shell can't read, and a query (`jql`) reaches the whole site
    static let agents = AgentAccess.reads
    func handle(_ forges: Forges) async throws -> Result {
        guard let jira = try await forges.jiraClient() else { return Result(connected: false) }
        guard let name = try await Forges.unlessRefused({ try await jira.myself() }) else {
            return Result(connected: false, site: jira.site)
        }
        return Result(connected: true, name: name, site: jira.site)
    }
}
extension JiraIssues: AsyncHandled {
    func handle(_ forges: Forges) async throws -> [JiraIssue] {
        guard let jira = try await forges.jiraClient() else {
            throw RPCError.invalidParams("Jira is not connected (Settings › Integrations)")
        }
        return try await jira.search(jql: jql ?? JiraClient.myOpenJQL)
    }
}
extension JiraTransitions: AsyncHandled {
    func handle(_ forges: Forges) async throws -> [JiraTransition] {
        guard let jira = try await forges.jiraClient() else { return [] }
        return try await jira.transitions(key: key)
    }
}
extension JiraTransitionIssue: AsyncHandled {
    func handle(_ forges: Forges) async throws -> Done {
        guard let jira = try await forges.jiraClient() else { throw RPCError.invalidParams("Jira is not connected") }
        try await jira.transition(key: key, id: id)
        return Done()
    }
}

extension Methods {
    static let trackerMethods: [any Answered.Type] = [
        LinearSetKey.self, LinearStatus.self, LinearIssues.self, LinearTeams.self, LinearStates.self,
        LinearSetState.self, JiraSetCredentials.self, JiraStatus.self, JiraIssues.self, JiraTransitions.self,
        JiraTransitionIssue.self
    ]
}
