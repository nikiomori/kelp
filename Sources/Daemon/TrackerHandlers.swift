import Core
import Foundation
import Integrations

// Linear and Jira: their keys, issues, teams, states and transitions.

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
    func handle(_ forges: Forges) async throws -> Result {
        guard let linear = await forges.linearClient() else { return Result(connected: false) }
        let me = try? await linear.viewer()
        return Result(connected: me != nil, name: me?.name ?? "")
    }
}
extension LinearIssues: AsyncHandled {
    func handle(_ forges: Forges) async throws -> [LinearIssue] {
        guard let linear = await forges.linearClient() else {
            throw RPCError.invalidParams("Linear is not connected (Settings › Integrations)")
        }
        if let teamId { return try await linear.teamIssues(teamId: teamId) }
        return try await linear.myIssues()
    }
}
extension LinearTeams: AsyncHandled {
    func handle(_ forges: Forges) async throws -> [LinearTeam] {
        guard let linear = await forges.linearClient() else { return [] }
        return try await linear.teams()
    }
}
extension LinearStates: AsyncHandled {
    func handle(_ forges: Forges) async throws -> [LinearState] {
        guard let linear = await forges.linearClient() else { return [] }
        return try await linear.workflowStates(teamId: teamId)
    }
}
extension LinearSetState: AsyncHandled {
    func handle(_ forges: Forges) async throws -> Done {
        guard let linear = await forges.linearClient() else { throw RPCError.invalidParams("Linear is not connected") }
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
    func handle(_ forges: Forges) async throws -> Result {
        guard let jira = await forges.jiraClient() else { return Result(connected: false) }
        let name = try? await jira.myself()
        return Result(connected: name != nil, name: name ?? "", site: jira.site)
    }
}
extension JiraIssues: AsyncHandled {
    func handle(_ forges: Forges) async throws -> [JiraIssue] {
        guard let jira = await forges.jiraClient() else {
            throw RPCError.invalidParams("Jira is not connected (Settings › Integrations)")
        }
        return try await jira.search(jql: jql ?? JiraClient.myOpenJQL)
    }
}
extension JiraTransitions: AsyncHandled {
    func handle(_ forges: Forges) async throws -> [JiraTransition] {
        guard let jira = await forges.jiraClient() else { return [] }
        return try await jira.transitions(key: key)
    }
}
extension JiraTransitionIssue: AsyncHandled {
    func handle(_ forges: Forges) async throws -> Done {
        guard let jira = await forges.jiraClient() else { throw RPCError.invalidParams("Jira is not connected") }
        try await jira.transition(key: key, id: id)
        return Done()
    }
}
