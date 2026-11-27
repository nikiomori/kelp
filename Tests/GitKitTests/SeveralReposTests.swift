import Foundation
import TestSupport
import Testing

@testable import Core
@testable import GitKit

/// A folder that holds repositories side by side: each one's files as its git lists them, under its name, and the rest
/// of the folder as it is. Before, the folder was walked as one, and each repository's ignored files came with it.
@Test func aFolderOfRepositoriesListsEachOnesFiles() throws {
    let parent = tmp().path
    for name in ["be", "fe"] {
        let repo = try tempRepo()
        try "build/\n".write(toFile: repo + "/.gitignore", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: repo + "/build", withIntermediateDirectories: true)
        try "x\n".write(toFile: repo + "/build/out.o", atomically: true, encoding: .utf8)
        try FileManager.default.moveItem(atPath: repo, toPath: parent + "/" + name)
    }
    try FileManager.default.createDirectory(atPath: parent + "/notes", withIntermediateDirectories: true)
    try "n\n".write(toFile: parent + "/notes/plan.md", atomically: true, encoding: .utf8)
    #expect(Git.nestedRepos(parent) == ["be", "fe"])
    #expect(Git.nestedRepos(parent + "/fe") == [])   // a repository holds none: it is one
    let files = try ProjectFiles.list(parent, remotes: .none)
    let each = ["f.txt", ".gitignore", ".env"]
    #expect(Set(files) == Set(each.map { "be/" + $0 } + each.map { "fe/" + $0 } + ["notes/plan.md"]))
    #expect(try ProjectFiles.ignored(parent, remotes: .none).sorted() == ["be/build/", "fe/build/"])
}

/// A repository's default branch read off its files says what `defaultBranch` asks git, so a folder of repositories
/// names each one's base without running git where its project's base is read.
@Test func theDefaultBranchReadOffTheFilesIsGits() throws {
    let repo = try tempRepo()
    #expect(Git.defaultBranchFromFiles(repo) == Git.defaultBranch(repo: repo, remotes: .none))
    try Git.run(["branch", "-m", "main", "trunk"], cwd: repo, remotes: .none)
    #expect(Git.defaultBranchFromFiles(repo) == "trunk")   // neither main nor master: the branch checked out
    try Git.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/dev"], cwd: repo, remotes: .none)
    #expect(Git.defaultBranchFromFiles(repo) == "dev")
    try Git.run(["pack-refs", "--all"], cwd: repo, remotes: .none)
    try Git.run(["symbolic-ref", "-d", "refs/remotes/origin/HEAD"], cwd: repo, remotes: .none)
    try Git.run(["branch", "master"], cwd: repo, remotes: .none)
    try Git.run(["pack-refs", "--all"], cwd: repo, remotes: .none)
    #expect(Git.defaultBranchFromFiles(repo) == "master")   // packed, as git keeps refs after a gc
}

/// A branch's folder of repositories holds what it was made with. A folder it links to that becomes a repository later is
/// the project's own checkout, and a repository cloned into the project later has no worktree there: neither is one of
/// the branch's, so its changes aren't shown or committed there, and the folder still closes.
@Test func aBranchFolderKeepsTheRepositoriesItWasMadeWith() throws {
    let project = tmp().path, dir = tmp()
    for name in ["be", "fe"] { try FileManager.default.moveItem(atPath: try tempRepo(), toPath: project + "/" + name) }
    try FileManager.default.createDirectory(atPath: project + "/notes", withIntermediateDirectories: true)
    let group = try Git.addWorktrees(project: project, branch: "b", into: dir, copyFiles: [], remotes: .none)
    try Git.run(["init", "-q", "-b", "main"], cwd: project + "/notes", remotes: .none)   // linked from the branch's folder
    try FileManager.default.moveItem(atPath: try tempRepo(), toPath: project + "/zz")   // cloned in after it was made
    #expect(Git.nestedRepos(project) == ["be", "fe", "notes", "zz"])
    #expect(Git.nestedRepos(group) == ["be", "fe"])
    #expect(Git.checkouts(project: project, folder: group).map(\.folder) == [group + "/be", group + "/fe"])
    #expect(Git.checkouts(project: project, folder: project).count == 4)   // the project's own: all of them
    try Git.removeWorktrees(project: project, path: group, branch: "b", force: true, remotes: .none)
    #expect(!FileManager.default.fileExists(atPath: group))
    #expect(FileManager.default.fileExists(atPath: project + "/notes/.git"))
}
