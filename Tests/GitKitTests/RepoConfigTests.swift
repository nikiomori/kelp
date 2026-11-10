import Core
import Foundation
import TestSupport
import Testing

@testable import GitKit

/// A folder that came with its own .git/config (a download, not a clone): what Kelp runs by itself must not start its programs.
@Test func aReposOwnConfigRunsNoProgramOnStatusOrDiff() throws {
    let repo = try tempRepo()
    let ran = repo + "/ran", script = repo + "/x.sh"
    try "#!/bin/sh\ntouch '\(ran)'\ncat \"$1\" 2>/dev/null\n".write(toFile: script, atomically: true, encoding: .utf8)
    chmod(script, 0o755)
    try Git.run(["config", "core.fsmonitor", script], cwd: repo, remotes: .none)
    try Git.run(["config", "diff.x.textconv", script], cwd: repo, remotes: .none)
    try Git.run(["config", "filter.x.clean", script + " %f"], cwd: repo, remotes: .none)
    try "*.txt diff=x filter=x\n".write(toFile: repo + "/.git/info/attributes", atomically: true, encoding: .utf8)
    try "a\nB\nc\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)   // the same size: status has to read it
    #expect(try Git.status(repo, remotes: .none).contains { $0.path == "f.txt" })
    #expect(try Git.diff(repo, source: .unstaged, remotes: .none).first?.hunks.isEmpty == false)
    #expect(!FileManager.default.fileExists(atPath: ran))
    // From a linked worktree too, whose config is the main repository's.
    let wt = try Git.addWorktree(
        repo: repo, branch: "w", base: "main", into: URL(fileURLWithPath: repo + "-wt"), copyFiles: [], remotes: .none)
    try "a\nB\nc\n".write(toFile: wt + "/f.txt", atomically: true, encoding: .utf8)
    try? FileManager.default.removeItem(atPath: ran)
    #expect(try Git.status(wt, remotes: .none).contains { $0.path == "f.txt" })
    #expect(!FileManager.default.fileExists(atPath: ran))
    try Git.run(["add", "f.txt"], cwd: repo, remotes: .none)   // what the user does keeps the repo's filter
    #expect(FileManager.default.fileExists(atPath: ran))
    try Git.run(["-c", "filter.x.clean=", "commit", "-qm", "two"], cwd: repo, remotes: .none)
    try FileManager.default.removeItem(atPath: ran)
    _ = try Git.run(["show", "HEAD"], cwd: repo, remotes: .none)   // any patch Kelp reads, not only Diff's
    _ = try Git.run(["log", "-p", "-1"], cwd: repo, remotes: .none)
    #expect(!FileManager.default.fileExists(atPath: ran))
}

/// A branch that commits a folder as a symlink out of the project can't have the user's ignored files copied there:
/// `.worktreeinclude` (a file the repository ships) names them, the copy stays inside the new worktree or doesn't happen.
@Test func copiedFilesStayInTheWorktree() throws {
    let repo = try tempRepo(), outside = tmp().path
    try FileManager.default.createDirectory(atPath: repo + "/conf", withIntermediateDirectories: true)
    try "TOKEN=1\n".write(toFile: repo + "/conf/.env", atomically: true, encoding: .utf8)
    try "conf/.env\n.env\n".write(toFile: repo + "/.gitignore", atomically: true, encoding: .utf8)
    try ".env\n".write(toFile: repo + "/.worktreeinclude", atomically: true, encoding: .utf8)
    try Git.run(["add", ".gitignore", ".worktreeinclude"], cwd: repo, remotes: .none)
    try Git.run(["commit", "-qm", "include"], cwd: repo, remotes: .none)
    try Git.run(["checkout", "-qb", "evil"], cwd: repo, remotes: .none)
    try FileManager.default.moveItem(atPath: repo + "/conf", toPath: repo + "/conf-real")
    try FileManager.default.createSymbolicLink(atPath: repo + "/conf", withDestinationPath: outside)
    try Git.run(["add", "conf"], cwd: repo, remotes: .none)
    try Git.run(["commit", "-qm", "link"], cwd: repo, remotes: .none)
    try Git.run(["checkout", "-q", "main"], cwd: repo, remotes: .none)   // takes the link away
    try FileManager.default.moveItem(atPath: repo + "/conf-real", toPath: repo + "/conf")
    let p = try Git.addWorktree(
        repo: repo, branch: "w", base: "evil", into: URL(fileURLWithPath: repo + "-wt"), copyFiles: ["conf/.env"], remotes: .none)
    #expect(!FileManager.default.fileExists(atPath: outside + "/.env"))
    #expect(FileManager.default.fileExists(atPath: p + "/.env"))   // one inside still comes
}

/// A folder's own git config (one that came as a download) runs no program when Kelp reads its history: no signature
/// is checked, whatever `log.showSignature` and `gpg.program` say.
@Test func readingHistoryRunsNoSignatureProgram() throws {
    let repo = try tempRepo()
    let marker = repo + "/ran", script = repo + "/gpg.sh"
    try "#!/bin/sh\ntouch \(marker)\n".write(toFile: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
    let tree = try Git.run(["write-tree"], cwd: repo, remotes: .none).trimmingCharacters(in: .whitespacesAndNewlines)
    let signed =
        "tree \(tree)\nauthor a <a@a> 0 +0000\ncommitter a <a@a> 0 +0000\ngpgsig -----BEGIN PGP SIGNATURE-----\n x\n -----END PGP SIGNATURE-----\n\nsigned\n"
    try signed.write(toFile: repo + "/commit.txt", atomically: true, encoding: .utf8)
    let sha = try Git.run(["hash-object", "-t", "commit", "-w", "commit.txt"], cwd: repo, remotes: .none).trimmingCharacters(
        in: .whitespacesAndNewlines)
    try Git.run(["update-ref", "HEAD", sha], cwd: repo, remotes: .none)
    try Git.run(["config", "log.showSignature", "true"], cwd: repo, remotes: .none)
    try Git.run(["config", "gpg.program", script], cwd: repo, remotes: .none)
    _ = try Git.run(["log", "--format=%h", "HEAD"], cwd: repo, remotes: .none)
    _ = try Git.run(["show", "--stat", "HEAD"], cwd: repo, remotes: .none)
    #expect(!FileManager.default.fileExists(atPath: marker))
}

/// A filter defined in a file the repo's config includes is turned off too, also one added there after the config was
/// last read: the cache follows the included file's stamp, not just .git/config's.
@Test func aFilterInAnIncludedConfigIsSeenWhenItChanges() throws {
    let repo = try tempRepo()
    try Git.run(["config", "include.path", "extra.cfg"], cwd: repo, remotes: .none)
    try "[filter \"x\"]\n\tclean = cat\n".write(toFile: repo + "/.git/extra.cfg", atomically: true, encoding: .utf8)
    #expect(RepoFilters.names(repo) == ["x"])
    try "[filter \"x\"]\n\tclean = cat\n[filter \"y\"]\n\tsmudge = cat\n".write(
        toFile: repo + "/.git/extra.cfg", atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: repo + "/.git/extra.cfg")
    #expect(RepoFilters.names(repo) == ["x", "y"])
}

/// Git splits `-c` at the first `=`, so a filter called `a=b` was skipped when listed and couldn't be turned off that way.
/// A name can hold spaces, tabs and dots too.
@Test func aFilterOfAnyNameIsTurnedOff() throws {
    for name in ["a=b", "c d", "e\tf", "g.h"] {
        let repo = try tempRepo()
        try Git.run(["config", "filter.\(name).clean", "cat"], cwd: repo, remotes: .none)
        #expect(RepoFilters.names(repo) == [name])
    }
    for name in ["a=b", "g.h"] {   // what .gitattributes can name
        let repo = try tempRepo()
        let marker = repo + "/.git/ran"
        try Git.run(["config", "filter.\(name).clean", "touch \(marker); cat"], cwd: repo, remotes: .none)
        try "* filter=\(name)\n".write(toFile: repo + "/.git/info/attributes", atomically: true, encoding: .utf8)
        try "changed\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
        _ = try Git.run(["status", "--short"], cwd: repo, remotes: .none)
        #expect(!FileManager.default.fileExists(atPath: marker), "\(name) status")
        _ = try Git.snapshotTree(repo, remotes: .none)
        #expect(!FileManager.default.fileExists(atPath: marker), "\(name)")
    }
}

/// The snapshot of a turn is Kelp's own `add`: nobody asked for a repository's hook on it.
@Test func aSnapshotRunsNoHook() throws {
    let repo = try tempRepo()
    let marker = repo + "/.git/ran", hook = repo + "/.git/hooks/post-index-change"
    try FileManager.default.createDirectory(atPath: repo + "/.git/hooks", withIntermediateDirectories: true)
    try "#!/bin/sh\ntouch \(marker)\n".write(toFile: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
    try "x\n".write(toFile: repo + "/f", atomically: true, encoding: .utf8)
    _ = try Git.snapshotTree(repo, remotes: .none)
    #expect(!FileManager.default.fileExists(atPath: marker))
}

/// A turn's snapshot is pinned under refs/kelp/turns: a new key or .env file, anywhere in the checkout, isn't written into
/// it (nor into git's objects); a tracked one is, as it's already in git.
@Test func aSnapshotLeavesNewSecretsOut() throws {
    let repo = try tempRepo()
    try FileManager.default.createDirectory(atPath: repo + "/sub/deep", withIntermediateDirectories: true)
    try "tracked\n".write(toFile: repo + "/sub/old.pem", atomically: true, encoding: .utf8)
    try Git.run(["add", "sub/old.pem"], cwd: repo, remotes: .none)
    try Git.run(["commit", "-qm", "a cert"], cwd: repo, remotes: .none)
    for f in [".env", "sub/deep/id_rsa", "sub/server.pem", "sub/credentials.json"] {
        try "SECRET-\(f)\n".write(toFile: repo + "/" + f, atomically: true, encoding: .utf8)
    }
    try "code\n".write(toFile: repo + "/sub/new.txt", atomically: true, encoding: .utf8)
    let tree = try Git.snapshotTree(repo + "/sub", remotes: .none)   // from a subfolder, as an agent working there
    let files = try Git.run(["ls-tree", "-r", "--name-only", tree], cwd: repo, remotes: .none).split(separator: "\n").map(String.init)
    #expect(files.contains("sub/new.txt") && files.contains("sub/old.pem"), "\(files)")
    #expect(
        !files.contains {
            ["id_rsa", "server.pem", "credentials.json", ".env"].contains(($0 as NSString).lastPathComponent)
        }, "\(files)")
    let secret = try Git.run(["hash-object", "--stdin"], cwd: repo, stdin: "SECRET-.env\n", remotes: .none).trimmingCharacters(
        in: .whitespacesAndNewlines)
    #expect(try Git.run(["cat-file", "--batch-check"], cwd: repo, stdin: secret + "\n", remotes: .none).contains("missing"))
}

/// A submodule's own config can define a filter too (`git status` runs in the submodule): it's turned off as well.
@Test func aSubmodulesFilterIsTurnedOffToo() throws {
    let repo = try tempRepo()
    let modules = repo + "/.git/modules/sub"
    try FileManager.default.createDirectory(atPath: modules, withIntermediateDirectories: true)
    try "[core]\n\tbare = false\n[filter \"evil\"]\n\tclean = touch ran\n".write(
        toFile: modules + "/config", atomically: true, encoding: .utf8)
    #expect(RepoFilters.names(repo).contains("evil"))
}

/// gh and glab run git themselves: the git they run turns off a repo's fsmonitor as Kelp's own does.
@Test func programsThatRunGitGetNoFsmonitor() throws {
    let repo = try tempRepo()
    let out = try Subprocess.output(
        ["/bin/sh", "-c", "printf %s \"$GIT_CONFIG_COUNT $GIT_CONFIG_KEY_0=$GIT_CONFIG_VALUE_0\""], cwd: repo,
        env: Git.toolEnv)
    #expect(String(decoding: out, as: UTF8.self) == "2 core.fsmonitor=false")
}
