import Foundation
import Testing

@testable import Core

/// What isn't there reads as nothing; what is reads whole, or its ends.
@Test func probesReadWhatIsThereAndNothingElse() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("kelp-probe-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { fm.removeIfAny(dir) }
    let file = dir.appendingPathComponent("f.txt"), missing = dir.appendingPathComponent("none")
    try Data("0123456789".utf8).write(to: file)

    #expect(String(contentsIfAny: file) == "0123456789")
    #expect(Data(head: 3, of: file) == Data("012".utf8))
    #expect(Data(head: 3, of: file, from: 8) == Data("89".utf8))
    #expect(Data(tail: 4, of: file) == Data("6789".utf8))
    #expect(Data(tail: 40, of: file) == Data("0123456789".utf8))
    #expect(Data(contentsIfAny: missing) == nil && String(contentsIfAny: missing) == nil)
    #expect(Data(tail: 4, of: missing) == nil)
    #expect(fm.items(in: dir).map(\.lastPathComponent) == ["f.txt"])
    #expect(fm.items(in: missing).isEmpty && fm.items(in: file).isEmpty)   // none there, a file there
    #expect(fm.names(in: dir.path) == ["f.txt"])
    fm.removeIfAny(missing)
    fm.removeIfAny(file)
    #expect(!fm.fileExists(atPath: file.path))
}

/// Not finding a program is an answer; `resolve` says it as an error.
@Test func findingAProgramIsAProbe() {
    #expect(LoginPath.find("sh", in: "/no-such-dir:/bin") == "/bin/sh")
    #expect(LoginPath.find("/bin/sh", in: "") == "/bin/sh")
    #expect(LoginPath.find("no-such-program-kelp", in: "/usr/bin:/bin") == nil)
    #expect(throws: RPCError.self) { try LoginPath.resolve("no-such-program-kelp", in: "/usr/bin:/bin") }
}
