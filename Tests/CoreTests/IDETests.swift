import Foundation
import Testing

@testable import Core

/// The starter's list command must print one JSON object per line using only stock tools.
@Test func scaffoldedExtensionWorks() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kx-\(UUID().uuidString.prefix(8))")
    let folder = try IDE.scaffoldExtension(id: "files", name: nil, description: "Top-level files", in: dir)
    #expect(try String(contentsOf: dir.appendingPathComponent("EXTENSIONS.md"), encoding: .utf8) == IDE.extensionGuide)
    #expect(IDE.extensionGuide.hasPrefix("# Writing Kelp extensions"))   // found in Core's resource bundle
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("README.md").path))
    let m = try JSONDecoder().decode(
        JSONValue.self, from: Data(contentsOf: folder.appendingPathComponent("extension.json")))
    #expect(m["id"] == "files" && m["description"] == "Top-level files")
    let command = try #require(m["contributes"]?["panels"]?.array?.first?["list"]?["command"]?.string)

    let work = dir.appendingPathComponent("work")
    try Paths.ensure(work)
    try "hi".write(to: work.appendingPathComponent("a b.txt"), atomically: true, encoding: .utf8)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", command]
    p.currentDirectoryURL = work
    let out = Pipe()
    p.standardOutput = out
    try p.run()
    p.waitUntilExit()
    let rows = (String(bytes: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "").split(
        separator: "\n"
    )
    .compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    #expect(rows == [.obj(["name": "./a b.txt", "size": 2])])

    #expect(throws: RPCError.self) { try IDE.scaffoldExtension(id: "files", name: nil, description: nil, in: dir) }   // exists
    #expect(
        !IDE.isValidExtensionID("Bad_ID") && !IDE.isValidExtensionID("..") && IDE.isValidExtensionID("docker.compose-2")
    )
}

@Test func openTargets() {
    #expect(IDE.uri(for: "https://x.dev/a", cwd: "/w") == "https://x.dev/a")
    #expect(IDE.uri(for: "a/b.swift", cwd: "/w") == "/w/a/b.swift")
    #expect(IDE.uri(for: "/abs/../c.swift", cwd: "/w") == "/c.swift")
    #expect(IDE.uri(for: "my file.swift:7", cwd: "/w") == "file:///w/my%20file.swift#L7")
    #expect(IDE.uri(for: "session:abc-def", cwd: "/w") == "session:abc-def")
}

@Test func droppedPathsAreBackslashEscaped() {
    #expect(IDE.escapedPath("/tmp/My File's (1).png") == #"/tmp/My\ File\'s\ \(1\).png"#)
    #expect(IDE.escapedPath(#"/a\b"#) == #"/a\\b"#)
    #expect(IDE.escapedPath("/plain/path.txt") == "/plain/path.txt")
}

/// Workspaces of a project share its folder: `kelp open` from an agent means that agent's own workspace.
@Test func workspaceOfTheCallingAgent() {
    let dir = FileManager.default.temporaryDirectory.path
    let all = [
        Worktree(id: "w1", repoId: "r", branch: "main", path: dir),
        Worktree(id: "w2", repoId: "r", branch: "main", path: dir),
        Worktree(id: "w3", repoId: "r", branch: "main", path: "/nowhere")
    ]
    #expect(IDE.workspace(cwd: dir, among: all, own: "w2")?.id == "w2")
    #expect(IDE.workspace(cwd: dir, among: all, own: nil)?.id == "w1")
    #expect(IDE.workspace(cwd: dir, among: all, own: "w3")?.id == "w1")   // its workspace isn't here
    #expect(IDE.workspace(cwd: "/elsewhere", among: all, own: "w2") == nil)
}

/// "Is this path in that folder" by what the paths are, not how they're spelled.
@Test func aPathIsInsideAFolderAsItReallyIs() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("in-\(UUID().uuidString.prefix(6))").path
    let folder = base + "/a/b"
    try FileManager.default.createDirectory(atPath: folder + "/c", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: base + "/a/bc", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: base + "/link", withDestinationPath: folder)
    try FileManager.default.createSymbolicLink(atPath: folder + "/out", withDestinationPath: base + "/a/bc")
    defer { try? FileManager.default.removeItem(atPath: base) }
    #expect(IDE.inside(folder, folder) && IDE.inside(folder + "/", folder) && IDE.inside(folder, folder + "/"))
    #expect(IDE.inside(folder + "/c/f.txt", folder) && IDE.inside(folder + "/not/there/yet.md", folder))
    #expect(!IDE.inside(base + "/a/bc", folder) && !IDE.inside(base + "/a/bc/f.txt", folder))   // a sibling named alike
    #expect(!IDE.inside(base + "/a", folder) && !IDE.inside("/", folder))
    #expect(IDE.inside(folder + "/c/../c/f", folder) && !IDE.inside(folder + "/../bc/f", folder))   // `..` followed
    #expect(IDE.inside(base + "/link/c", folder) && IDE.inside(folder + "/c", base + "/link"))   // through a link
    #expect(IDE.inside(base + "/link/new/x.md", folder))   // through a link, not there yet
    #expect(!IDE.inside(folder + "/out/f", folder))   // a link out of the folder
    let real = try #require(Paths.real(folder)), plain = real.replacingOccurrences(of: "/private/", with: "/")
    #expect(IDE.inside(plain + "/c", real) && IDE.inside(real + "/new", plain))   // /tmp is /private/tmp
    #expect(IDE.inside("x/../y", FileManager.default.currentDirectoryPath))   // relative: from the current folder
    #expect(IDE.inside("/a/b", "/") && !IDE.inside("/", "/a"))
}

/// The daemon's placeholder is a new chat to people; a name someone gave it, or a first prompt did, stays.
@Test func aWorkspaceNobodyNamedIsANewChat() {
    func workspace(_ note: String) -> Worktree { Worktree(repoId: "r", branch: "main", path: "/p", note: note) }
    #expect(workspace("Workspace 3").isUnnamed && workspace("Workspace 3").displayName != "Workspace 3")
    #expect(!workspace("Workspace plans").isUnnamed && workspace("Workspace plans").displayName == "Workspace plans")
    #expect(!workspace("").isUnnamed && workspace("").displayName == "main")
}
