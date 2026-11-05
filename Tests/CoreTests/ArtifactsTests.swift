import Foundation
import Testing
@testable import Core

private func tempRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ka-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/info"), withIntermediateDirectories: true)
    return root
}

@Test func artifactSlugs() {
    #expect(Artifacts.slug("GRDB 7: four decisions") == "grdb-7-four-decisions")
    #expect(Artifacts.slug("План миграции") == "plan-migracii")
    #expect(Artifacts.slug("…") == "artifact")
    #expect(Artifacts.slug(String(repeating: "word ", count: 20)).count <= 48)
}

/// A page gets a folder of its own, a record naming the chat, and the folder stays out of git once.
@Test func artifactCreateAndList() throws {
    let root = try tempRoot()
    let first = try Artifacts.create(.review, title: "GRDB 7: four decisions", root: root.path, session: "s1", now: Date(timeIntervalSince1970: 1))
    #expect(first.path.hasSuffix(".kelp/artifacts/grdb-7-four-decisions/review.md"))
    #expect(try String(contentsOf: first, encoding: .utf8) == "# GRDB 7: four decisions\n\n")
    let second = try Artifacts.create(.doc, title: "GRDB 7: four decisions", root: root.path, session: nil, now: Date(timeIntervalSince1970: 2))
    #expect(second.deletingLastPathComponent().lastPathComponent == "grdb-7-four-decisions-2")

    let all = Artifacts.list(root: root.path)
    #expect(all.map(\.slug) == ["grdb-7-four-decisions-2", "grdb-7-four-decisions"])   // newest first
    #expect(all[1].record == ArtifactRecord(type: "review", title: "GRDB 7: four decisions", created: Date(timeIntervalSince1970: 1), session: "s1", file: "review.md"))
    #expect(Artifacts.target(all[1].slug, all[1].record, root: root.path) == first.path)

    let exclude = try String(contentsOf: root.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
    #expect(exclude == "/.kelp/artifacts/\n")
}

/// A worktree's `.git` is a file; its exclude is the main repository's.
@Test func artifactExcludeInWorktree() throws {
    let repo = try tempRoot(), wt = repo.appendingPathComponent("wt")
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git/worktrees/wt"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
    try "gitdir: \(repo.path)/.git/worktrees/wt\n".write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    try "*.log".write(to: repo.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
    try Artifacts.excludeFromGit(root: wt.path)
    try Artifacts.excludeFromGit(root: wt.path)
    #expect(try String(contentsOf: repo.appendingPathComponent(".git/info/exclude"), encoding: .utf8) == "*.log\n/.kelp/artifacts/\n")
}

/// What claude-artifacts answers a publish with: the link is kept once, a later version of it isn't a new page.
@Test func artifactFromHook() throws {
    let answer = #"{"slug":"28647d38","title":"Kelp 0.9 for the team","url":"https://claude.ai/artifact/5zJ6vqH1KMUVNFw1ztTGRL","version":"1"}"#
    func hook(_ event: String, _ tool: String) -> JSONValue {
        .obj(["hook_event_name": .string(event), "tool_name": .string(tool), "tool_input": .obj(["files": .array([])]),
              "tool_response": .array([.obj(["type": "text", "text": .string(answer)])])])
    }
    let p = try #require(Artifacts.published(hook: hook("PostToolUse", "mcp__claude-artifacts__publish_files")))
    #expect(p.url == "https://claude.ai/artifact/5zJ6vqH1KMUVNFw1ztTGRL" && p.title == "Kelp 0.9 for the team" && p.type == "page")
    #expect(Artifacts.published(hook: hook("PreToolUse", "mcp__claude-artifacts__publish_files")) == nil)
    #expect(Artifacts.published(hook: hook("PostToolUse", "Bash")) == nil)

    let root = try tempRoot()
    #expect(try Artifacts.addNative(url: p.url, title: p.title, type: p.type, root: root.path, session: "s1") != nil)
    #expect(try Artifacts.addNative(url: p.url, title: p.title, type: p.type, root: root.path, session: "s1") == nil)
    let only = try #require(Artifacts.list(root: root.path).first)
    #expect(Artifacts.target(only.slug, only.record, root: root.path) == p.url && only.record.file == nil)
}

/// The agent's own artifacts come first unless the user keeps them on this Mac; reviews always stay.
@Test func artifactGuides() throws {
    let doc = try #require(Artifacts.guide("doc", whereTo: "agent"))
    #expect(doc.contains("If you can publish artifacts yourself") && doc.contains("kelp artifact new doc"))
    let local = try #require(Artifacts.guide("doc", whereTo: "local"))
    #expect(local.contains("don't publish it elsewhere") && !local.contains("If you can publish"))
    let review = try #require(Artifacts.guide("review", whereTo: "agent"))
    #expect(review.contains("Reviews stay in the project") && review.contains("## 1. The question"))
    let slides = try #require(Artifacts.guide("slides", whereTo: "agent"))
    #expect(slides.contains("make it there") && !slides.contains("kelp artifact new"))
    #expect(Artifacts.guide("poster", whereTo: "agent") == nil)
}
