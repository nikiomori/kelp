import Agents
import Core
import Foundation
import GitKit
import TestSupport
import Testing
import os

@testable import Daemon

private func clearKeys() {
    for a in [Forges.linearKeyAccount, Forges.jiraAccount, Forges.bitbucketAccount] { Keychain.delete(a) }
}

private let viewer = #"{"data":{"viewer":{"id":"u1","name":"Ada","email":"ada@x.io"}}}"#

// These share one set of keychain accounts (and Linear / Bitbucket have fixed hosts), so they run one after another.
@Suite(.serialized) struct FixedHostHandlers {
    @Test func linearIsValidatedBeforeItsKeyIsKept() async throws {
        let (d, c, _) = try daemon()
        defer {
            d.stop()
            clearKeys()
        }
        #expect(try await c.call("linear.status")["connected"]?.bool == false)
        StubURL.serve("api.linear.app") { _ in (401, "nope") }
        await #expect(throws: (any Error).self) { _ = try await c.call("linear.setKey", .obj(["key": "bad"])) }
        #expect(try await c.call("linear.status")["connected"]?.bool == false)   // the bad key wasn't saved
        StubURL.serve("api.linear.app") { _ in (200, viewer) }
        #expect(try await c.call("linear.setKey", .obj(["key": "good"]))["name"]?.string == "Ada")
        let s = try await c.call("linear.status")
        #expect(s["connected"]?.bool == true && s["name"]?.string == "Ada")
        _ = try await c.call("linear.setKey", .obj(["key": ""]))   // an empty key disconnects
        #expect(try await c.call("linear.status")["connected"]?.bool == false)
    }

    @Test func linearListsIssuesTeamsStatesAndMovesAnIssue() async throws {
        let (d, c, _) = try daemon()
        defer {
            d.stop()
            clearKeys()
        }
        StubURL.serve("api.linear.app") { r in
            if r.body.contains("viewer { id name email }") { return (200, viewer) }
            if r.body.contains("assignedIssues") {
                return (
                    200,
                    #"{"data":{"viewer":{"assignedIssues":{"nodes":[{"id":"i1","identifier":"ENG-1","title":"Fix","description":"","url":"u","#
                        + #""branchName":"eng-1","state":{"id":"s","name":"Todo","type":"unstarted"},"team":{"id":"t","key":"ENG","name":"Eng"}}]}}}}"#
                )
            }
            if r.body.contains("teams {") {
                return (200, #"{"data":{"teams":{"nodes":[{"id":"t","key":"ENG","name":"Eng"}]}}}"#)
            }
            if r.body.contains("states {") {
                return (
                    200,
                    #"{"data":{"team":{"states":{"nodes":[{"id":"s1","name":"Todo","type":"unstarted"},{"id":"s2","name":"In Progress","type":"started"}]}}}}"#
                )
            }
            if r.body.contains("issueUpdate") { return (200, #"{"data":{"issueUpdate":{"success":true}}}"#) }
            return (400, #"{"errors":[{"message":"unexpected"}]}"#)
        }
        _ = try await c.call("linear.setKey", .obj(["key": "k"]))
        #expect(try await c.call("linear.issues").array?.first?["identifier"]?.string == "ENG-1")
        #expect(try await c.call("linear.teams").array?.first?["key"]?.string == "ENG")
        #expect(try await c.call("linear.states", .obj(["teamId": "t"])).array?.count == 2)
        _ = try await c.call("linear.setState", .obj(["issueId": "i1", "stateId": "s2"]))
        await #expect(throws: (any Error).self) { _ = try await c.call("linear.states", .obj([:])) }   // the team id is required
    }

    @Test func withoutALinearKeyListsAreEmptyAndIssuesAskForTheKey() async throws {
        let (d, c, _) = try daemon()
        defer {
            d.stop()
            clearKeys()
        }
        clearKeys()
        #expect(try await c.call("linear.teams").array?.isEmpty == true)
        await #expect(throws: (any Error).self) { _ = try await c.call("linear.issues") }
        await #expect(throws: (any Error).self) {
            _ = try await c.call("linear.setState", .obj(["issueId": "i", "stateId": "s"]))
        }
    }

    /// A Bitbucket pull request opens from the branch checked out now, the one just pushed: a workspace's record can still
    /// name the branch it had before a switch.
    @Test func aBitbucketPullRequestComesFromTheBranchCheckedOut() async throws {
        let (d, c, _) = try daemon()
        defer {
            d.stop()
            clearKeys()
        }
        let sent = OSAllocatedUnfairLock(initialState: "")
        StubURL.serve("api.bitbucket.org") { r in
            sent.withLock { $0 = r.body }
            return (201, #"{"links":{"html":{"href":"https://bitbucket.org/w/r/pull-requests/7"}}}"#)
        }
        _ = try await c.call("bitbucket.setCredentials", .obj(["user": "me", "token": "t"]))
        let path = try makeRepo(), bare = tmp().path + ".git"
        try Git.run(["init", "-q", "--bare", bare], cwd: "/tmp", remotes: .none)
        try Git.run(["remote", "add", "origin", "git@bitbucket.org:w/r.git"], cwd: path, remotes: .none)
        try Git.run(["config", "url.\(bare).pushInsteadOf", "git@bitbucket.org:w/r.git"], cwd: path, remotes: .none)   // pushes stay here
        let repo: Repo = try await c.call("repo.add", .obj(["path": .string(path)]), as: Repo.self)
        let w = try #require(try await c.call("worktree.list", as: [Worktree].self).first { $0.repoId == repo.id })
        try Git.run(["checkout", "-qb", "switched-to"], cwd: w.path, remotes: .none)   // outside Kelp: its record still says the old branch
        try "x".write(toFile: w.path + "/x.txt", atomically: true, encoding: .utf8)
        try Git.run(["add", "."], cwd: w.path, remotes: .none)
        try Git.run(["commit", "-qm", "x"], cwd: w.path, remotes: .none)
        _ = try await c.call("github.pr-create", .obj(["worktreeId": .string(w.id), "title": "T", "body": "B"]))
        #expect(sent.withLock { $0 }.contains(#""source":{"branch":{"name":"switched-to"}}"#))
    }

    /// A Bitbucket pull request merges through Bitbucket's API, and without its credentials says so: gh never runs for
    /// one (it looked the number up on whatever GitHub repository it found).
    @Test func aBitbucketPullRequestMergesOnBitbucketOrNotAtAll() async throws {
        let (d, c, _) = try daemon()
        defer {
            d.stop()
            clearKeys()
        }
        clearKeys()
        let path = try makeRepo()
        try Git.run(["remote", "add", "origin", "git@bitbucket.org:w/r.git"], cwd: path, remotes: .none)
        let repo: Repo = try await c.call("repo.add", .obj(["path": .string(path)]), as: Repo.self)
        let w = try #require(try await c.call("worktree.list", as: [Worktree].self).first { $0.repoId == repo.id })
        let merge = JSONValue.obj(["worktreeId": .string(w.id), "pr": .int(7)])
        await #expect(throws: Forges.bitbucketNeedsCredentials) { _ = try await c.call("github.pr-merge", merge) }
        let asked = OSAllocatedUnfairLock(initialState: "")
        StubURL.serve("api.bitbucket.org") { r in
            asked.withLock { $0 = r.method + " " + r.path }
            return (200, "{}")
        }
        _ = try await c.call("bitbucket.setCredentials", .obj(["user": "me", "token": "t"]))
        _ = try await c.call("github.pr-merge", merge)
        #expect(asked.withLock { $0 }.hasSuffix("/repositories/w/r/pullrequests/7/merge"), "\(asked.withLock { $0 })")
    }

    @Test func bitbucketCredentialsAreKeptOrCleared() async throws {
        let (d, c, _) = try daemon()
        defer {
            d.stop()
            clearKeys()
        }
        clearKeys()
        #expect(try await c.call("bitbucket.status")["connected"]?.bool == false)
        _ = try await c.call("bitbucket.setCredentials", .obj(["user": "me", "token": "t"]))
        #expect(try await c.call("bitbucket.status")["connected"]?.bool == true)
        _ = try await c.call("bitbucket.setCredentials", .obj(["user": "me", "token": ""]))
        #expect(try await c.call("bitbucket.status")["connected"]?.bool == false)
    }

    @Test func jiraIsValidatedListsIssuesAndMovesThem() async throws {
        let host = "jira-\(UUID().uuidString.prefix(6).lowercased()).test"
        let (d, c, _) = try daemon()
        defer {
            d.stop()
            clearKeys()
        }
        clearKeys()
        #expect(try await c.call("jira.status")["connected"]?.bool == false)
        await #expect(throws: (any Error).self) { _ = try await c.call("jira.issues") }
        #expect(try await c.call("jira.transitions", .obj(["key": "ENG-1"])).array?.isEmpty == true)   // not connected: nothing to list
        let moves = Moves()
        StubURL.serve(host) { r in
            if r.path.hasSuffix("/myself") { return (200, #"{"displayName":"Ada"}"#) }
            if r.path.contains("/search") {
                return (
                    200,
                    #"{"issues":[{"key":"ENG-1","fields":{"summary":"Fix","status":{"name":"To Do","statusCategory":{"key":"new"}},"#
                        + #""issuetype":{"name":"Bug"},"project":{"key":"ENG"}}}]}"#
                )
            }
            if r.path.hasSuffix("/transitions"), r.body.isEmpty {
                return (
                    200,
                    #"{"transitions":[{"id":"11","name":"Start","to":{"statusCategory":{"key":"indeterminate"}}}]}"#
                )
            }
            if r.path.hasSuffix("/transitions") {
                moves.add(r.body)
                return (204, "")
            }
            return (404, "")
        }
        #expect(
            try await c.call("jira.setCredentials", .obj(["site": .string(host), "email": "a@b.c", "token": "tok"]))[
                "name"]?.string == "Ada")
        let st = try await c.call("jira.status")
        #expect(st["connected"]?.bool == true && st["name"]?.string == "Ada")
        #expect(try await c.call("jira.issues").array?.first?["key"]?.string == "ENG-1")
        #expect(try await c.call("jira.transitions", .obj(["key": "ENG-1"])).array?.first?["id"]?.string == "11")
        _ = try await c.call("jira.transition", .obj(["key": "ENG-1", "id": "11"]))
        #expect(moves.all.contains { $0.contains(#""id":"11""#) })
        _ = try await c.call("jira.setCredentials", .obj(["site": .string(host), "email": "a@b.c", "token": ""]))
        #expect(try await c.call("jira.status")["connected"]?.bool == false)
    }
}

private final class Moves: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
}

@Test func agentSecretsGoToTheKeychainAndAnEmptyValueRemovesThem() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let agent = "demo-\(UUID().uuidString.prefix(6))"
    let account = AgentManifest.secretAccount(agent: agent, key: "API_KEY")
    defer { Keychain.delete(account) }
    #expect(Keychain.get(account) == nil)
    _ = try await c.call("agent.setSecret", .obj(["agent": .string(agent), "key": "API_KEY", "value": "s3cret"]))
    #expect(Keychain.get(account) == "s3cret")
    _ = try await c.call("agent.setSecret", .obj(["agent": .string(agent), "key": "API_KEY", "value": ""]))
    #expect(Keychain.get(account) == nil)
}
