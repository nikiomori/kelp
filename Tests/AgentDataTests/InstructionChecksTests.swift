import Core
import Foundation
import TestSupport
import Testing

@testable import AgentData

private func put(_ text: String, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

@Test func memoryIndexPastClaudesLimitCountsTheLinesNeverRead() throws {
    let root = tmp(), memory = root.appendingPathComponent("memory")
    let lines = (1...230).map { "- [Note \($0)](note_\($0).md) — hook" }
    try put(lines.joined(separator: "\n") + "\n", memory.appendingPathComponent("MEMORY.md"))
    try put("one", memory.appendingPathComponent("note_1.md"))
    try put("not indexed", memory.appendingPathComponent("stray.md"))
    try put("archived", memory.appendingPathComponent("archive/note_2.md"))
    let check = try #require(InstructionChecks.check(memory.appendingPathComponent("MEMORY.md").path, cwd: root.path))
    #expect(check.lines == 230)
    #expect(check.cut == 30)
    #expect(check.missing == 229)
    #expect(check.unlisted == 1)
    #expect(check.needsLook)
}

@Test func deadPathsAreOnlyThoseInTheProjectsOwnFolders() throws {
    let root = tmp()
    try put("", root.appendingPathComponent("Sources/Core/Paths.swift"))
    let text = """
        Paths live in `Sources/Core/Paths.swift`; seeding was in Sources/Daemon/HomeSeed.swift.
        Not the project's: and/or.md, ~/.kelp/x.json, https://claude.ai/artifact/abc.html, ./Sources/a.swift.
        """
    try put(text, root.appendingPathComponent("AGENTS.md"))
    let check = try #require(InstructionChecks.check(root.appendingPathComponent("AGENTS.md").path, cwd: root.path))
    #expect(check.dead == ["Sources/Daemon/HomeSeed.swift"])
    #expect(check.cut == 0)
    #expect(check.maxBytes == 32_768)
}

@Test func aShortHealthyFileNeedsNoLook() throws {
    let root = tmp()
    try put("# Notes\n- run `swift test`\n", root.appendingPathComponent("CLAUDE.md"))
    let check = try #require(InstructionChecks.check(root.appendingPathComponent("CLAUDE.md").path, cwd: root.path))
    #expect(check.lines == 2)
    #expect(!check.needsLook)
    #expect(InstructionChecks.check(root.appendingPathComponent("none.md").path, cwd: root.path) == nil)
}
