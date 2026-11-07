import Foundation
import Testing

@testable import Core
@testable import GitKit

/// git's output past twice the budget isn't kept: a diff that prints 17 MB comes back with the files read before the
/// cut, and the rest named, header only, like files past the budget.
@Test func aDiffPastWhatsReadNamesTheRest() throws {
    let repo = try tempRepo()
    let line = String(repeating: "x", count: 99) + "\n"
    try "a\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
    try String(repeating: line, count: 170_000).write(toFile: repo + "/huge.txt", atomically: true, encoding: .utf8)   // 17 MB
    try "z\n".write(toFile: repo + "/z.txt", atomically: true, encoding: .utf8)
    try Git.run(["add", "a.txt", "huge.txt", "z.txt"], cwd: repo)
    let d = try Git.diff(repo, source: .staged)
    #expect(d.map(\.path) == ["a.txt", "huge.txt", "z.txt"])
    #expect(d.first?.tooLarge == nil && d.first?.additions == 1)
    #expect(d.dropFirst().allSatisfy { $0.tooLarge == true })   // z.txt came after the cut: never read
}

/// A status lists the first `FileChange.limit` changes (a folder that should be ignored can hold far more), and so does
/// the file list its own limit; without a limit, git's whole answer.
@Test func aStatusPastItsLimitListsTheFirst() throws {
    let repo = try tempRepo()
    let made = try Subprocess.run(
        ["/bin/sh", "-c", "mkdir n && cd n && seq 10005 | xargs touch"], cwd: repo,
        env: ProcessInfo.processInfo.environment, timeLimit: 60)
    #expect(made.status == 0)
    #expect(try Git.status(repo, limit: FileChange.limit).count == FileChange.limit)
    #expect(try Git.status(repo).count == 10_006)   // .env too
    #expect(try ProjectFiles.list(repo, limit: 10_000).count == 10_000)
    #expect(try ProjectFiles.list(repo).count == 10_007)   // f.txt and .env too
}
