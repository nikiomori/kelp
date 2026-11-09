import Foundation
import Testing

@testable import Core

private func tempRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ka-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent(".git/info"), withIntermediateDirectories: true)
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
    let first = try Artifacts.create(
        .review, title: "GRDB 7: four decisions", root: root.path, session: "s1", now: Date(timeIntervalSince1970: 1))
    #expect(first.path.hasSuffix(".kelp/artifacts/grdb-7-four-decisions/review.md"))
    #expect(try String(contentsOf: first, encoding: .utf8) == "# GRDB 7: four decisions\n\n")
    let second = try Artifacts.create(
        .doc, title: "GRDB 7: four decisions", root: root.path, session: nil, now: Date(timeIntervalSince1970: 2))
    #expect(second.deletingLastPathComponent().lastPathComponent == "grdb-7-four-decisions-2")

    let all = Artifacts.list(root: root.path)
    #expect(all.map(\.slug) == ["grdb-7-four-decisions-2", "grdb-7-four-decisions"])   // newest first
    #expect(
        all[1].record
            == ArtifactRecord(
                type: "review", title: "GRDB 7: four decisions", created: Date(timeIntervalSince1970: 1), session: "s1",
                file: "review.md"))
    #expect(Artifacts.target(all[1].slug, all[1].record, root: root.path) == first.path)

    let exclude = try String(contentsOf: root.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
    #expect(exclude == "/.kelp/artifacts/\n")
}

/// A design and a dashboard are pages of HTML, titled; slides are Markdown. Their versions keep their file's extension.
@Test func artifactKinds() throws {
    let root = try tempRoot()
    let design = try Artifacts.create(.design, title: "Header <A & B>", root: root.path, session: "s1")
    #expect(design.lastPathComponent == "design.html")
    let html = try String(contentsOf: design, encoding: .utf8)
    #expect(html.contains("<title>Header &lt;A &amp; B&gt;</title>") && html.contains("color-scheme: light dark"))
    #expect(
        try Artifacts.create(.dashboard, title: "CI", root: root.path, session: nil).lastPathComponent
            == "dashboard.html")
    #expect(
        try Artifacts.create(.slides, title: "Deck", root: root.path, session: nil).lastPathComponent == "slides.md")
    #expect(try Artifacts.keepVersions(root: root.path, session: "s1", label: "make it") == 1)
    #expect(Artifacts.versionPath(target: design.path, 1).hasSuffix("/versions/1.html"))
    #expect(FileManager.default.fileExists(atPath: Artifacts.versionPath(target: design.path, 1)))
}

/// A worktree's `.git` is a file; its exclude is the main repository's.
@Test func artifactExcludeInWorktree() throws {
    let repo = try tempRoot(), wt = repo.appendingPathComponent("wt")
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent(".git/worktrees/wt"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
    try "gitdir: \(repo.path)/.git/worktrees/wt\n".write(
        to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    try "*.log".write(to: repo.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
    try Artifacts.excludeFromGit(root: wt.path)
    try Artifacts.excludeFromGit(root: wt.path)
    #expect(
        try String(contentsOf: repo.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
            == "*.log\n/.kelp/artifacts/\n")
}

/// What claude-artifacts answers a publish with: the link is kept once, a later version of it isn't a new page.
@Test func artifactFromHook() throws {
    let answer =
        #"{"slug":"28647d38","title":"Kelp 0.9 for the team","url":"https://claude.ai/artifact/5zJ6vqH1KMUVNFw1ztTGRL","version":"1"}"#
    func hook(_ event: String, _ tool: String) -> JSONValue {
        .obj([
            "hook_event_name": .string(event), "tool_name": .string(tool), "tool_input": .obj(["files": .array([])]),
            "tool_response": .array([.obj(["type": "text", "text": .string(answer)])])
        ])
    }
    let p = try #require(Artifacts.published(hook: hook("PostToolUse", "mcp__claude-artifacts__publish_files")))
    #expect(
        p.url == "https://claude.ai/artifact/5zJ6vqH1KMUVNFw1ztTGRL" && p.title == "Kelp 0.9 for the team"
            && p.type == "page")
    #expect(Artifacts.published(hook: hook("PreToolUse", "mcp__claude-artifacts__publish_files")) == nil)
    #expect(Artifacts.published(hook: hook("PostToolUse", "Bash")) == nil)
    // Reading or listing names pages too (a type's own, someone else's): not published here.
    #expect(Artifacts.published(hook: hook("PostToolUse", "mcp__claude-artifacts__list_types")) == nil)
    #expect(Artifacts.published(hook: hook("PostToolUse", "mcp__claude-artifacts__read_artifact")) == nil)
    #expect(Artifacts.published(hook: hook("PostToolUse", "mcp__claude_ai_Claude_Docs__batch")) != nil)

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
    #expect(slides.contains("make it there") && slides.contains("kelp artifact new slides") && slides.contains("`---`"))
    let design = try #require(Artifacts.guide("design", whereTo: "local"))
    #expect(design.contains("don't publish it elsewhere") && design.contains("light and dark"))
    #expect(Artifacts.guide("poster", whereTo: "agent") == nil)
}

/// The panel's list: a review's answers counted from its file, its last save; a page on a service only its link.
@Test func artifactItems() throws {
    let root = try tempRoot()
    let page = try Artifacts.create(
        .review, title: "Two points", root: root.path, session: "s1", now: Date(timeIntervalSince1970: 1))
    try "# Two points\n\n## 1. One\n- [x] A. Yes\n- [ ] B. No\n\n## 2. Two\n- [ ] A. Yes\n".write(
        to: page, atomically: true, encoding: .utf8)
    _ = try Artifacts.addNative(
        url: "https://claude.ai/artifact/abc", title: "Deck", type: "page", root: root.path, session: nil,
        now: Date(timeIntervalSince1970: 2))
    let items = Artifacts.items(root: root.path)
    #expect(items.map(\.title) == ["Two points", "Deck"])   // by the last change: the review was just saved
    #expect(items[1].target == "https://claude.ai/artifact/abc" && items[1].modified == nil && items[1].points == nil)
    #expect(items[0].points == 2 && items[0].answered == 1 && items[0].session == "s1" && items[0].created == 1)
    #expect(items[0].target == page.path && (items[0].modified ?? 0) > Date().timeIntervalSince1970 - 60)
}

/// A turn's end keeps a version of each page its chat made, only when the page changed, and the last 20 of them.
@Test func artifactVersions() throws {
    let root = try tempRoot()
    let page = try Artifacts.create(.doc, title: "Plan", root: root.path, session: "s1")
    _ = try Artifacts.create(.doc, title: "Other chat's", root: root.path, session: "s2")
    #expect(try Artifacts.keepVersions(root: root.path, session: "s1", label: "make a plan\nwith details") == 1)
    #expect(try Artifacts.keepVersions(root: root.path, session: "s1", label: "nothing changed") == 0)
    var item = try #require(Artifacts.items(root: root.path).first { $0.title == "Plan" })
    #expect(item.versions?.map(\.label) == ["make a plan"] && item.changed == false)
    try "# Plan\n\nMore.\n".write(to: page, atomically: true, encoding: .utf8)
    item = try #require(Artifacts.items(root: root.path).first { $0.title == "Plan" })
    #expect(item.changed == true)
    #expect(try Artifacts.keepVersions(root: root.path, session: "s1", label: "") == 1)
    #expect(try String(contentsOfFile: Artifacts.versionPath(target: page.path, 1), encoding: .utf8) == "# Plan\n\n")
    #expect(Artifacts.items(root: root.path).first { $0.title == "Plan" }?.versions?.last?.label == "Turn 2")
    #expect(Artifacts.items(root: root.path).first { $0.title == "Other chat's" }?.versions == nil)

    for i in 3...23 {
        try "# Plan\n\n\(i)\n".write(to: page, atomically: true, encoding: .utf8)
        try Artifacts.keepVersions(root: root.path, session: "s1", label: "turn \(i)")
    }
    let versions = try #require(Artifacts.items(root: root.path).first { $0.title == "Plan" }?.versions)
    #expect(versions.count == 20 && versions.first?.n == 4 && versions.last?.n == 23)
    #expect(!FileManager.default.fileExists(atPath: Artifacts.versionPath(target: page.path, 3)))
    #expect(FileManager.default.fileExists(atPath: Artifacts.versionPath(target: page.path, 4)))
    // An old version already gone (deleted by hand) doesn't stop the next one being kept.
    try FileManager.default.removeItem(atPath: Artifacts.versionPath(target: page.path, 4))
    try "# Plan\n\n24\n".write(to: page, atomically: true, encoding: .utf8)
    #expect(try Artifacts.keepVersions(root: root.path, session: "s1", label: "turn 24") == 1)
    #expect(Artifacts.items(root: root.path).first { $0.title == "Plan" }?.versions?.last?.n == 24)
}

/// A cloned repository can commit `.kelp/artifacts/x/artifact.json`: it lists only a web page's link or a file in its
/// own folder, and a page that is a link to a device (`/dev/zero` never ends) is never read.
@Test(.timeLimit(.minutes(1))) func aCommittedArtifactIsReadWithCare() throws {
    let root = try tempRoot(), base = Artifacts.dir(root: root.path)
    func add(_ name: String, _ json: String) throws {
        let f = base.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        try json.write(to: f.appendingPathComponent("artifact.json"), atomically: true, encoding: .utf8)
    }
    let made = #""created":"2026-11-05T00:00:00Z","type":"doc","title":"x""#
    try add("smb", "{\(made),\"url\":\"smb://evil/share\"}")
    try add("up", "{\(made),\"file\":\"../../../etc/passwd\"}")
    try add("web", "{\(made),\"url\":\"https://claude.ai/artifact/abc\"}")
    try add("zero", "{\(made),\"file\":\"doc.md\"}")
    try FileManager.default.createSymbolicLink(
        atPath: base.appendingPathComponent("zero/doc.md").path, withDestinationPath: "/dev/zero")
    #expect(Artifacts.list(root: root.path).map(\.slug).sorted() == ["web", "zero"])
    #expect(Artifacts.items(root: root.path).contains { $0.slug == "zero" })   // listed, its endless file not read
}

/// A page published again moves to the top with its new time; what the tool sent of it is kept for the preview: the
/// whole page, a canvas's first board (which makes it a design), or edits to the copy.
@Test func artifactPageCopies() throws {
    let root = try tempRoot(), url = "https://claude.ai/artifact/xyz"
    func hook(_ tool: String, _ input: JSONValue) -> JSONValue {
        .obj([
            "hook_event_name": "PostToolUse", "tool_name": .string("mcp__claude-artifacts__\(tool)"),
            "tool_input": input,
            "tool_response": .array([.obj(["type": "text", "text": .string(#"{"title":"Plan","url":"\#(url)"}"#)])])
        ])
    }
    let first = try #require(Artifacts.published(hook: hook("publish_version", .obj(["content": "<p>one two</p>"]))))
    #expect(first.type == "page" && first.page == .html("<p>one two</p>"))
    _ = try Artifacts.addNative(
        url: url, title: first.title, type: first.type, root: root.path, session: nil, page: first.page,
        now: Date(timeIntervalSince1970: 1))
    _ = try Artifacts.create(.doc, title: "Later", root: root.path, session: nil, now: Date(timeIntervalSince1970: 2))
    let copy = try #require(Artifacts.items(root: root.path).first { $0.url == url }?.preview)
    #expect(try String(contentsOfFile: copy, encoding: .utf8) == "<p>one two</p>")

    let edit = try #require(
        Artifacts.published(
            hook: hook("edit_version", .obj(["edits": .array([.obj(["old_text": "two", "new_text": "three"])])]))))
    _ = try Artifacts.addNative(
        url: url, title: edit.title, type: edit.type, root: root.path, session: nil, page: edit.page,
        now: Date().addingTimeInterval(60))
    #expect(try String(contentsOfFile: copy, encoding: .utf8) == "<p>one three</p>")
    let items = Artifacts.items(root: root.path)
    #expect(items.first?.url == url && items.count == 2)   // published again: before the later doc

    let board = root.appendingPathComponent("Main.dc.html")
    try "<div>board</div>".write(to: board, atomically: true, encoding: .utf8)
    let files: JSONValue = .array([
        .obj(["as": "project/canvas.json", "path": "/nowhere/canvas.json"]),
        .obj(["as": "project/Main.dc.html", "path": .string(board.path)])
    ])
    let canvas = try #require(Artifacts.published(hook: hook("publish_files", .obj(["files": files]))))
    #expect(canvas.type == "design" && canvas.page == .file(board.path))
    _ = try Artifacts.addNative(
        url: url, title: canvas.title, type: canvas.type, root: root.path, session: nil, page: canvas.page)
    #expect(Artifacts.items(root: root.path).first { $0.url == url }?.type == "design")
    #expect(try String(contentsOfFile: copy, encoding: .utf8) == "<div>board</div>")
}
