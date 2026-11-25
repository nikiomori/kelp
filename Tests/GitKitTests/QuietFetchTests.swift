import Foundation
import TestSupport
import Testing

@testable import Core
@testable import GitKit

/// What git says when a fetch fails, read as the reason the popover's line gives, and the host it names.
@Test(
    arguments: [
        (
            "fatal: unable to access 'https://github.com/o/r.git/': Could not resolve host: github.com", .offline,
            "github.com"
        ),
        ("ssh: Could not resolve hostname gitlab.com: nodename nor servname provided", .offline, "gitlab.com"),
        ("ssh: connect to host github.com port 22: Operation timed out", .offline, "github.com"),
        ("Can't reach devbox: Connection closed by 10.0.0.2 port 22", .offline, "devbox"),
        (
            "git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.", .signIn,
            "github.com"
        ),
        ("fatal: Authentication failed for 'https://github.com/o/r.git/'", .signIn, "github.com"),
        (
            "fatal: could not read Username for 'https://gitlab.example.com': terminal prompts disabled", .signIn,
            "gitlab.example.com"
        ),
        ("Host key verification failed.\nfatal: Could not read from remote repository.", .signIn, nil),
        ("fatal: 'origin' does not appear to be a git repository", .other, nil)
    ] as [(String, QuietFetch.Trouble, String?)])
func aFailedFetchSaysWhy(said: String, trouble: QuietFetch.Trouble, host: String?) {
    #expect(Git.trouble(said) == trouble)
    #expect(Git.host(said) == host)
}

/// A background fetch never asks: ssh runs in batch mode, after the repository's own ssh command, and a credential
/// manager is told not to open a window.
@Test func aQuietFetchCantAsk() throws {
    let repo = try tempRepo()
    var env = try Git.quietEnv(repo, remotes: .none)
    #expect(env["GIT_SSH_COMMAND"]?.hasSuffix(" -o BatchMode=yes") == true)
    let key = env.first { $0.value == "credential.interactive" }?.key
    #expect(key.map { env[$0.replacingOccurrences(of: "KEY", with: "VALUE")] } == "never")
    try Git.run(["config", "core.sshCommand", "ssh -i ~/.ssh/work"], cwd: repo, remotes: .none)
    env = try Git.quietEnv(repo, remotes: .none)
    #expect(env["GIT_SSH_COMMAND"] == "ssh -i ~/.ssh/work -o BatchMode=yes")
}

/// A fetch that works brings the commits and says when; one that can't reach its remote says why and leaves the time
/// of the last fetch that worked, though git rewrote FETCH_HEAD.
@Test func aQuietFetchKeepsTheLastGoodFetchsTime() throws {
    let repo = try tempRepo(), bare = tmp().path
    try Git.run(["init", "-q", "--bare", "-b", "main"], cwd: bare, remotes: .none)
    try Git.run(["remote", "add", "origin", bare], cwd: repo, remotes: .none)
    try Git.run(["push", "-q", "-u", "origin", "main"], cwd: repo, remotes: .none)
    let worked = try Git.fetchQuietly(repo, remotes: .none)
    #expect(worked.ran && worked.trouble == nil)
    #expect(abs((worked.fetched ?? 0) - Date().timeIntervalSince1970) < 60)

    let head = try Git.fetchHead(repo, remotes: .none), old = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: head)
    try Git.run(["remote", "set-url", "origin", "https://nonexistent.invalid/r.git"], cwd: repo, remotes: .none)
    let failed = try Git.fetchQuietly(repo, remotes: .none)
    #expect(failed.ran && failed.trouble == .offline && failed.host == "nonexistent.invalid", "\(failed)")
    #expect(failed.fetched == old.timeIntervalSince1970)
    #expect(try Git.lastFetch(repo, remotes: .none) == old.timeIntervalSince1970)
}
