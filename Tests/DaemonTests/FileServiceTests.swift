import Core
import Foundation
import Testing

@testable import Daemon

/// A file is read with its stamp, and refused the way a tab refuses one: a pipe, past the size limit, not UTF-8, gone.
@Test func aFileIsReadWithItsStampAndRefusedLikeATab() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let dir = tmp().path
    try "hello\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
    let r = try await c.call(FilesRead(path: dir + "/a.txt"))
    #expect(r.text == "hello\n" && !r.stamp.isEmpty)
    #expect(try await c.call(FilesRead(path: dir + "/a.txt")).stamp == r.stamp)   // unchanged: the same stamp
    func refusal(_ name: String) async -> Unopenable? {
        do {
            _ = try await c.call(FilesRead(path: dir + "/" + name))
            return nil
        } catch { return Unopenable(error) }
    }
    #expect(FileManager.default.createFile(atPath: dir + "/big.log", contents: nil))
    #expect(truncate(dir + "/big.log", 60 << 20) == 0)   // sparse
    #expect(await refusal("big.log") == .tooBig(60 << 20))
    try Data([0x63, 0x61, 0x66, 0xE9, 0x0A]).write(to: URL(fileURLWithPath: dir + "/latin1.txt"))   // "café" in Latin-1
    #expect(await refusal("latin1.txt") == .binary)
    #expect(mkfifo(dir + "/pipe", 0o600) == 0)
    #expect(await refusal("pipe") == .special)
    do {
        _ = try await c.call(FilesRead(path: dir + "/gone.txt"))
        Issue.record("read a file that isn't there")
    } catch { #expect("\(error)".contains("moved or deleted")) }
    await #expect(throws: (any Error).self) { _ = try await c.call(FilesRead(path: "a.txt")) }   // relative: whose folder?
}

/// A save goes in only over the version it was read as: an agent's edit meanwhile comes back to ask about, a file that's
/// gone isn't brought back, and a symlink keeps pointing at the file it was written through.
@Test func aWriteGoesInOnlyOverTheVersionItWasGiven() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let dir = tmp().path, file = dir + "/a.txt"
    try "one\n".write(toFile: file, atomically: true, encoding: .utf8)
    let read = try await c.call(FilesRead(path: file))
    let wrote = try await c.call(FilesWrite(path: file, text: "two\n", base: read.stamp))
    let stamp = try #require(wrote.stamp)
    #expect(try String(contentsOfFile: file, encoding: .utf8) == "two\n" && stamp != read.stamp)
    #expect(try await c.call(FilesRead(path: file)).stamp == stamp)

    try "an agent's\n".write(toFile: file, atomically: true, encoding: .utf8)
    let conflict = try #require(try await c.call(FilesWrite(path: file, text: "mine\n", base: stamp)).conflict)
    #expect(conflict.text == "an agent's\n")
    #expect(try String(contentsOfFile: file, encoding: .utf8) == "an agent's\n")   // not written
    // Keep Mine: no base, written whatever is there.
    #expect(try await c.call(FilesWrite(path: file, text: "mine\n", base: nil)).stamp != nil)
    #expect(try String(contentsOfFile: file, encoding: .utf8) == "mine\n")

    try Data([0xE9, 0x0A]).write(to: URL(fileURLWithPath: file))   // not UTF-8 now: a conflict with no text
    let notText = try #require(try await c.call(FilesWrite(path: file, text: "x\n", base: stamp)).conflict)
    #expect(notText.text == nil)

    let last = try #require(try await c.call(FilesWrite(path: file, text: "last\n", base: nil)).stamp)
    try FileManager.default.removeItem(atPath: file)   // moved or deleted under the tab
    #expect(try await c.call(FilesWrite(path: file, text: "back\n", base: last)).missing == true)
    #expect(!FileManager.default.fileExists(atPath: file))

    try "target\n".write(toFile: dir + "/target.txt", atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: dir + "/link.txt", withDestinationPath: dir + "/target.txt")
    let link = try await c.call(FilesRead(path: dir + "/link.txt"))
    #expect(try await c.call(FilesWrite(path: dir + "/link.txt", text: "through\n", base: link.stamp)).stamp != nil)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dir + "/link.txt") == dir + "/target.txt")
    #expect(try String(contentsOfFile: dir + "/target.txt", encoding: .utf8) == "through\n")

    // Past the limit a tab opens: refused, nothing written (called here: 50 MB through the socket would only be slower).
    do {
        _ = try FileService(remotes: .none).write(
            dir + "/huge.txt", String(repeating: "x", count: Unopenable.openLimit + 1), base: nil)
        Issue.record("wrote past the limit")
    } catch { #expect(Unopenable(error) == .tooBig(Unopenable.openLimit + 1)) }
    #expect(!FileManager.default.fileExists(atPath: dir + "/huge.txt"))
}

/// The Files panel's operations: Finder's names for copies and new files, a move that stops at the first failure and
/// says which went, and the Trash saying where each item went so ⌘Z can move it back.
@Test func filesMoveTrashCopyAndCreateLikeTheFilesPanel() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let dir = tmp().path
    let fm = FileManager.default
    func name(_ p: String) -> String { (p as NSString).lastPathComponent }

    #expect(name(try await c.call(FilesCreate(path: dir + "/untitled", unique: true))) == "untitled")
    #expect(name(try await c.call(FilesCreate(path: dir + "/untitled", unique: true))) == "untitled 2")
    await #expect(throws: (any Error).self) { _ = try await c.call(FilesCreate(path: dir + "/untitled")) }   // taken
    let note = try await c.call(FilesCreate(path: dir + "/docs/plans/plan.md", text: "# Plan\n"))
    #expect(try String(contentsOfFile: note, encoding: .utf8) == "# Plan\n")
    var isDir: ObjCBool = false
    _ = try await c.call(FilesCreate(path: dir + "/src/lib", folder: true))
    #expect(fm.fileExists(atPath: dir + "/src/lib", isDirectory: &isDir) && isDir.boolValue)

    try "a\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
    #expect(try await c.call(FilesCopy(paths: [dir + "/a.txt"], into: dir)).made.map(name) == ["a copy.txt"])
    #expect(try await c.call(FilesCopy(paths: [dir + "/a.txt"], into: dir)).made.map(name) == ["a copy 2.txt"])

    // Moved onto a taken name: "name copy", when asked to.
    let moved = try await c.call(
        FilesMove(pairs: [FileMove(from: dir + "/a copy.txt", to: dir + "/a.txt")], unique: true))
    #expect(moved.done.map { name($0.to) } == ["a copy 3.txt"] && moved.error == nil)
    // The second's source is gone: the first is moved, the third isn't, and the reply says so.
    let partly = try await c.call(
        FilesMove(pairs: [
            FileMove(from: dir + "/a.txt", to: dir + "/b.txt"), FileMove(from: dir + "/nope", to: dir + "/x"),
            FileMove(from: dir + "/untitled", to: dir + "/c")
        ]))
    #expect(partly.done.map { name($0.to) } == ["b.txt"] && partly.error != nil)
    #expect(fm.fileExists(atPath: dir + "/untitled") && !fm.fileExists(atPath: dir + "/c"))

    let trashed = try await c.call(FilesTrash(paths: [dir + "/b.txt"]))
    let there = try #require(trashed.done.first?.to)
    defer { try? fm.removeItem(atPath: there) }   // if the undo below failed: not left in the user's Trash
    #expect(!fm.fileExists(atPath: dir + "/b.txt") && fm.fileExists(atPath: there))
    // ⌘Z: moved back from where the Trash put it.
    _ = try await c.call(FilesMove(pairs: [FileMove(from: there, to: dir + "/b.txt")]))
    #expect(try String(contentsOfFile: dir + "/b.txt", encoding: .utf8) == "a\n")
}

/// A remote project's file is read and written on its host through the same methods, its stamp the bytes' digest: an
/// agent's edit there is asked about; a file made there is made on the host, not in the folder here.
@Test func aRemoteFileIsWrittenOnlyOverTheVersionRead() async throws {
    _ = localSSH
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let there = try makeRepo()
    let repo = try await c.call(RepoAddRemote(host: "box", path: there))
    let file = repo.path + "/a.txt"
    let read = try await c.call(FilesRead(path: file))
    #expect(read.text == "hello\n" && read.stamp == FileService.digest(Data("hello\n".utf8)))
    let wrote = try await c.call(FilesWrite(path: file, text: "édité ✓\n", base: read.stamp))
    #expect(try String(contentsOfFile: there + "/a.txt", encoding: .utf8) == "édité ✓\n")
    try "an agent's\n".write(toFile: there + "/a.txt", atomically: true, encoding: .utf8)
    #expect(
        try await c.call(FilesWrite(path: file, text: "mine\n", base: wrote.stamp)).conflict?.text == "an agent's\n")
    try FileManager.default.removeItem(atPath: there + "/a.txt")
    #expect(try await c.call(FilesWrite(path: file, text: "mine\n", base: wrote.stamp)).missing == true)
    // The old method, as an older app calls it: a file that's gone is written again.
    #expect(try await c.call(FilesWriteRemote(path: file, text: "again\n", base: "édité ✓\n")) == nil)
    #expect(try String(contentsOfFile: there + "/a.txt", encoding: .utf8) == "again\n")
    // Made there, never in the folder here (`aRemoteProjectsFilesAreChangedOnItsHost`).
    _ = try await c.call(FilesCreate(path: repo.path + "/new.txt"))
    #expect(FileManager.default.fileExists(atPath: there + "/new.txt"))
    #expect(!FileManager.default.fileExists(atPath: repo.path + "/new.txt"))
}

/// An upload cut short (the connection dropped) looks finished to the host's `cat`: the file isn't written with half of it.
@Test func aRemoteSaveCutShortLeavesTheFile() async throws {
    _ = localSSH
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let there = try makeRepo()
    try "kept\n".write(toFile: there + "/cut-short.txt", atomically: true, encoding: .utf8)
    let repo = try await c.call(RepoAddRemote(host: "box", path: there))
    await #expect(throws: (any Error).self) {
        _ = try await c.call(FilesWrite(path: repo.path + "/cut-short.txt", text: "a longer text\n", base: nil))
    }
    #expect(try String(contentsOfFile: there + "/cut-short.txt", encoding: .utf8) == "kept\n")
}

/// A file's round trip through the socket (read, then a save of the same size), as a tab makes it. Opt-in:
/// KELP_BENCH=1 swift test --filter fileRoundTrip. Budgets: 200 KB ≤ 10 ms, 5 MB ≤ 150 ms.
@Test(.enabled(if: ProcessInfo.processInfo.environment["KELP_BENCH"] != nil)) func fileRoundTrip() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let dir = tmp().path
    for (size, budget) in [(200 << 10, 0.010), (5 << 20, 0.150)] {
        let line = "let value = compute(input, with: options) // a line of code\n"
        let text = String(repeating: line, count: size / line.utf8.count), file = dir + "/f\(size).swift"
        try text.write(toFile: file, atomically: true, encoding: .utf8)
        var best = Double.infinity
        for _ in 0..<5 {
            let start = Date()
            let r = try await c.call(FilesRead(path: file))
            _ = try await c.call(FilesWrite(path: file, text: r.text, base: r.stamp))
            best = min(best, Date().timeIntervalSince(start))
        }
        print(
            "BENCH files.read + files.write \(size >> 10) KB: \(String(format: "%.1f", best * 1000)) ms (budget \(Int(budget * 1000)) ms)"
        )
        #expect(best <= budget)
    }
}

/// A saved script stays executable (Foundation's atomic write keeps the old file's permissions: this holds it to that).
@Test func aSaveKeepsTheFilesPermissions() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let file = tmp().path + "/deploy.sh"
    try "#!/bin/sh\n".write(toFile: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file)
    let read = try await c.call(FilesRead(path: file))
    _ = try await c.call(FilesWrite(path: file, text: "#!/bin/sh\necho hi\n", base: read.stamp))
    #expect((try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int) == 0o755)
}
