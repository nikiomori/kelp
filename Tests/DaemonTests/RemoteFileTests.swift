import Foundation
import Testing
import Core
@testable import Daemon

/// A remote project's file is refused the way a tab here refuses one: a pipe, past the size limit, not UTF-8. It used to
/// be read whole and decoded lossily, so a Latin-1 file saved back had U+FFFD for each byte that wasn't UTF-8.
@Test func aRemoteFileIsRefusedLikeALocalOneAndNeverWrittenLossily() async throws {
    _ = localSSH
    let (d, c, _) = try daemon(); defer { d.stop() }
    let there = try makeRepo()
    let repo = try await c.call(RepoAddRemote(host: "box", path: there))
    func read(_ name: String) async -> Result<String, Error> {
        do { return .success(try await c.call(FilesReadRemote(path: repo.path + "/" + name))) } catch { return .failure(error) }
    }
    func refusal(_ name: String) async -> Unopenable? {
        guard case .failure(let e) = await read(name) else { return nil }
        return Unopenable(e)
    }
    #expect(try await c.call(FilesReadRemote(path: repo.path + "/a.txt")) == "hello\n")
    #expect(FileManager.default.createFile(atPath: there + "/big.log", contents: nil))
    #expect(truncate(there + "/big.log", 60 << 20) == 0)   // sparse
    #expect(await refusal("big.log") == .tooBig(60 << 20))
    let latin1 = Data([0x63, 0x61, 0x66, 0xE9, 0x0A])   // "café" in Latin-1
    try latin1.write(to: URL(fileURLWithPath: there + "/latin1.txt"))
    #expect(await refusal("latin1.txt") == .binary)
    // A client that read it lossily (an older app) saves: refused, the file stays as it was.
    await #expect(throws: (any Error).self) {
        _ = try await c.call(FilesWriteRemote(path: repo.path + "/latin1.txt", text: "café, edited\n", base: "caf\u{FFFD}\n"))
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: there + "/latin1.txt")) == latin1)
    #expect(mkfifo(there + "/pipe", 0o600) == 0)
    #expect(await refusal("pipe") == .special)   // (the old code blocked here forever: not run against it)
}

/// A diff of a remote project reads every untracked file on the host in one ssh round trip, not one per file.
@Test func aRemoteDiffReadsUntrackedFilesInOneRoundTrip() async throws {
    _ = localSSH
    let (d, c, _) = try daemon(); defer { d.stop() }
    let there = try makeRepo()
    for i in 1...5 { try "file \(i)\n".write(toFile: there + "/new\(i).txt", atomically: true, encoding: .utf8) }
    let repo = try await c.call(RepoAddRemote(host: "box", path: there))
    let w = try #require(try await c.call(WorktreeList(repoId: repo.id)).first)
    let log = URL(fileURLWithPath: localSSH).deletingLastPathComponent().appendingPathComponent("ssh.log"), name = (there as NSString).lastPathComponent
    func reads() -> Int {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.contains("head -c 1000001") && $0.contains(name) }.count
    }
    let before = reads()
    let diffs = try await c.call(GitDiff(id: w.id, source: "unstaged"))
    #expect((1...5).allSatisfy { i in diffs.first { $0.path == "new\(i).txt" }?.hunks.first?.lines.map(\.text) == ["file \(i)"] })
    #expect(reads() - before == 1)
}

/// A remote image or PDF is copied here for its preview (Quick Look and PDFKit read a file), byte for byte, binary or not.
@Test func aRemoteImageIsCopiedHereForItsPreview() async throws {
    _ = localSSH
    let (d, c, _) = try daemon(); defer { d.stop() }
    let there = try makeRepo()
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF])
    try png.write(to: URL(fileURLWithPath: there + "/shot.png"))
    let repo = try await c.call(RepoAddRemote(host: "box", path: there))
    let copy = try await c.call(FilesFetch(path: repo.path + "/shot.png"))
    #expect(copy != there + "/shot.png" && copy.hasSuffix("/shot.png"))
    #expect(try Data(contentsOf: URL(fileURLWithPath: copy)) == png)
    await #expect(throws: (any Error).self) { _ = try await c.call(FilesFetch(path: repo.path + "/gone.png")) }
}

/// A remote project's icon is looked for on its host where a project here would be, and kept in its folder here: shown
/// at once next time (without the host), looked for again behind it.
@Test func aRemoteProjectsIconIsFoundOnItsHostAndKept() async throws {
    _ = localSSH
    let (d, c, _) = try daemon(); defer { d.stop() }
    let there = try makeRepo(), fm = FileManager.default
    for dir in ["public", "docs", "App/Assets.xcassets/AppIcon.appiconset"] { try fm.createDirectory(atPath: there + "/" + dir, withIntermediateDirectories: true) }
    let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8)
    try svg.write(to: URL(fileURLWithPath: there + "/public/favicon.svg"))
    try Data("png".utf8).write(to: URL(fileURLWithPath: there + "/docs/logo.png"))   // a worse name
    let repo = try await c.call(RepoAddRemote(host: "box", path: there))
    let kept = repo.path + "/.kelp-icon/favicon.svg"
    #expect(try await c.call(RepoIcon(path: repo.path)) == kept)
    #expect(try Data(contentsOf: URL(fileURLWithPath: kept)) == svg)

    // An Xcode AppIcon set's largest PNG, once nothing better is there; the kept one answers until it's found.
    try fm.removeItem(atPath: there + "/public"); try fm.removeItem(atPath: there + "/docs")
    try Data(repeating: 1, count: 10).write(to: URL(fileURLWithPath: there + "/App/Assets.xcassets/AppIcon.appiconset/small.png"))
    try Data(repeating: 2, count: 99).write(to: URL(fileURLWithPath: there + "/App/Assets.xcassets/AppIcon.appiconset/big.png"))
    #expect(try await c.call(RepoIcon(path: repo.path)) == kept)
    #expect(try await waitFor(10) { !fm.fileExists(atPath: kept) })
    #expect(try await c.call(RepoIcon(path: repo.path)) == repo.path + "/.kelp-icon/big.png")

    try fm.removeItem(atPath: there + "/App")
    _ = try await c.call(RepoIcon(path: repo.path))
    #expect(try await waitFor(10) { !fm.fileExists(atPath: repo.path + "/.kelp-icon") })
    #expect(try await c.call(RepoIcon(path: repo.path)) == nil)
}
