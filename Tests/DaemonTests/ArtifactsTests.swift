import Foundation
import Testing
import os

@testable import Core
@testable import Daemon

private func tempRoot() throws -> URL {
    let root = tmp().appendingPathComponent("ka-\(UUID().uuidString.prefix(8))")
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

/// Pages with one title made at once (two `kelp artifact new "Plan"`) each get a folder of their own.
@Test func artifactsMadeAtOnceGetAFolderEach() throws {
    let root = try tempRoot()
    _ = try Artifacts.create(.doc, title: "Plan", root: root.path, session: nil)   // the artifacts folder there
    let made = OSAllocatedUnfairLock<[String]>(initialState: [])
    DispatchQueue.concurrentPerform(iterations: 16) { _ in
        let page = try? Artifacts.create(.doc, title: "Plan", root: root.path, session: nil)
        made.withLock { $0.append(page?.deletingLastPathComponent().lastPathComponent ?? "failed") }
    }
    let folders = made.withLock { $0 }
    #expect(Set(folders).count == 16 && !folders.contains("failed"), "\(folders.sorted())")
}

/// A design and a dashboard are canvases (their boards in boards/); slides are Markdown. Their versions keep their
/// file's extension.
@Test func artifactKinds() throws {
    let root = try tempRoot()
    let design = try Artifacts.create(.design, title: "Header", root: root.path, session: "s1")
    #expect(design.lastPathComponent == "canvas.json")
    #expect(try String(contentsOf: design, encoding: .utf8) == ArtifactCanvas.empty)
    var isFolder: ObjCBool = false
    #expect(
        FileManager.default.fileExists(
            atPath: design.deletingLastPathComponent().appendingPathComponent("boards").path, isDirectory: &isFolder)
            && isFolder.boolValue)
    let dashboard = try Artifacts.create(.dashboard, title: "CI", root: root.path, session: nil)
    #expect(dashboard.lastPathComponent == "canvas.json")
    #expect(
        try Artifacts.create(.slides, title: "Deck", root: root.path, session: nil).lastPathComponent == "slides.md")
    #expect(try Artifacts.create(.proof, title: "Fix", root: root.path, session: nil).lastPathComponent == "proof.md")
    let motion = try Artifacts.create(.motion, title: "Launch <1>", root: root.path, session: nil)
    #expect(motion.lastPathComponent == "motion.html")
    #expect(try String(contentsOf: motion, encoding: .utf8).contains(#"<title>Launch &lt;1&gt;</title>"#))
    #expect(try Artifacts.keepVersions(root: root.path, session: "s1", label: "make it") == 1)
    #expect(Artifacts.versionPath(target: design.path, 1).hasSuffix("/versions/1.json"))
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
    // A proof's pictures are files beside it, so it stays too; it lists only what was run, and says what wasn't.
    let proof = try #require(Artifacts.guide("proof", whereTo: "agent"))
    #expect(proof.contains("Proofs stay in the project") && !proof.contains("If you can publish"))
    #expect(
        proof.contains("kelp artifact new proof") && proof.contains("## Not checked") && proof.contains("width=\"49%\"")
    )
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

/// A page made before its chat started (From File) is that chat's once a turn's prompt names it: it keeps versions
/// of that turn and of the next ones.
@Test func aPageNamedInAChatsPromptIsThatChats() throws {
    let root = try tempRoot()
    let page = try Artifacts.create(.doc, title: "From file", root: root.path, session: nil)
    #expect(try Artifacts.keepVersions(root: root.path, session: "s1", label: "Make a page") == 0)
    #expect(
        try Artifacts.keepVersions(root: root.path, session: "s1", label: "Fill \(Artifacts.projectPath(page.path))")
            == 1)
    try "# More\n".write(to: page, atomically: true, encoding: .utf8)
    #expect(try Artifacts.keepVersions(root: root.path, session: "s1", label: "and more") == 1)
    #expect(Artifacts.items(root: root.path).first?.session == "s1")
}

/// A version kept from a record read before another version was kept takes the next number, not the same one.
@Test func versionsKeptFromAnOldRecordDontOverwriteEachOther() throws {
    let root = try tempRoot()
    let page = try Artifacts.create(.doc, title: "Plan", root: root.path, session: "s1")
    let (slug, stale) = try #require(Artifacts.list(root: root.path).first)
    #expect(try Artifacts.keepVersion(slug, stale, root: root.path, label: "turn", now: Date()))
    try "# Plan\n\nBy hand.\n".write(to: page, atomically: true, encoding: .utf8)
    #expect(try Artifacts.keepVersion(slug, stale, root: root.path, label: "By hand", byUser: true, now: Date()))
    #expect(Artifacts.items(root: root.path).first?.versions?.map(\.n) == [1, 2])
}

/// A cloned repository can commit `.kelp/artifacts/x/artifact.json`: it lists only a web page's link or a file in its
/// own folder, and a page that is a link to a device (`/dev/zero` never ends) is never read.
@Test(.timeLimit(minutes: 1)) func aCommittedArtifactIsReadWithCare() throws {
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

/// A page published before Kelp kept copies gets one from its chat's transcript: the calls whose answer names it,
/// replayed in order (the page, then an edit), once.
@Test func artifactPagesAreRecoveredFromTheTranscript() throws {
    let root = try tempRoot(), url = "https://claude.ai/artifact/old"
    _ = try Artifacts.addNative(url: url, title: "Old", type: "page", root: root.path, session: "S1")
    func call(_ id: String, _ tool: String, _ input: String) -> String {
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"\#(id)","#
            + #""name":"mcp__claude-artifacts__\#(tool)","input":\#(input)}]}}"#
    }
    func answer(_ id: String, _ text: String) -> String {
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)","#
            + #""content":[{"type":"text","text":"\#(text)"}]}]}}"#
    }
    let lines = [
        call("a", "publish_version", #"{"content":"<p>one two</p>"}"#), answer("a", #"{\"url\":\"\#(url)\"}"#),
        call("b", "publish_version", #"{"content":"<p>someone else's</p>"}"#),
        answer("b", "https://claude.ai/artifact/other"),
        call("c", "edit_version", #"{"edits":[{"old_text":"two","new_text":"three"}]}"#), answer("c", url)
    ]
    let transcript = root.appendingPathComponent("s1.jsonl")
    try lines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
    var asked: [String] = []
    let find: (String) -> URL? = { id in
        asked.append(id)
        return transcript
    }
    #expect(Artifacts.recoverPages(root: root.path, transcript: find) == 1)
    let item = try #require(Artifacts.items(root: root.path).first)
    #expect(try String(contentsOfFile: try #require(item.preview), encoding: .utf8) == "<p>one three</p>")
    #expect(Artifacts.recoverPages(root: root.path, transcript: find) == 0 && asked == ["S1"])   // looked for once
}

/// `kelp artifact new|add` and an agent's hook ask the daemon, the one writer of the records: a page published again is
/// the same one, with the copy of what was sent.
@Test func theDaemonWritesTheArtifacts() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let root = try tempRoot()
    let file = try await c.call(ArtifactNew(kind: .doc, title: "Plan", cwd: root.path, session: nil))
    #expect(file.hasSuffix("/.kelp/artifacts/plan/doc.md") && FileManager.default.fileExists(atPath: file))
    let add = ArtifactAdd(
        url: "https://claude.ai/artifact/abc", title: "Deck", type: "page", cwd: root.path, session: nil,
        page: .html("<p>hi</p>"))
    #expect(try await c.call(add))
    #expect(try await !c.call(add))
    let page = try #require(Artifacts.list(root: root.path).first { $0.record.url != nil })
    let copy = Artifacts.dir(root: root.path).appendingPathComponent(page.slug).appendingPathComponent(
        Artifacts.pageCopy)
    #expect(try String(contentsOf: copy, encoding: .utf8) == "<p>hi</p>")
    await #expect(throws: RPCError.self) {
        try await c.call(ArtifactNew(kind: .doc, title: "Plan", cwd: "relative/folder", session: nil))
    }
    // A check is the window's to make: none is connected here, and only a canvas is checked.
    let canvas = try await c.call(ArtifactNew(kind: .design, title: "Home", cwd: root.path, session: nil))
    await #expect(throws: RPCError.self) { try await c.call(ArtifactCheck(path: canvas)) }
    await #expect(throws: RPCError.self) { try await c.call(ArtifactCheck(path: file)) }
    // What a chat spent is read from its Claude Code transcript: a page with no chat has none.
    #expect(try await c.call(ArtifactCost(path: file)) == nil)
    #expect(try await c.call(ArtifactCost(path: root.path + "/elsewhere.md")) == nil)
}

/// A design's version keeps its canvas with its boards' text, and a board's change makes a new one.
@Test func aCanvasVersionKeepsItsBoards() throws {
    let root = try tempRoot()
    let canvas = try Artifacts.create(.design, title: "Home", root: root.path, session: "s1")
    try #"{"boards": [{"file": "boards/A.html"}]}"#.write(to: canvas, atomically: true, encoding: .utf8)
    let board = canvas.deletingLastPathComponent().appendingPathComponent("boards/A.html")
    try "<p>one</p>".write(to: board, atomically: true, encoding: .utf8)
    #expect(try Artifacts.keepVersions(root: root.path, session: "s1", label: "first") == 1)
    #expect(try Artifacts.keepVersions(root: root.path, session: "s1", label: "nothing new") == 0)
    try "<p>two</p>".write(to: board, atomically: true, encoding: .utf8)
    #expect(try Artifacts.keepVersions(root: root.path, session: "s1", label: "second") == 1)
    let first = try #require(Artifacts.versionText(target: canvas.path, 1).flatMap(CanvasSnapshot.read))
    #expect(first.boards == ["boards/A.html": "<p>one</p>"])
}

/// A canvas's time moves with its boards and the design system, which it is drawn with.
@Test func aCanvasTimeFollowsItsBoardsAndTheSystem() throws {
    let root = try tempRoot()
    let canvas = try Artifacts.create(.design, title: "Home", root: root.path, session: nil)
    let before = try #require(Artifacts.canvasTime(canvas.path, root: root.path))
    let board = canvas.deletingLastPathComponent().appendingPathComponent("boards/A.html")
    try "<p>hi</p>".write(to: board, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: before + 5)], ofItemAtPath: board.path)
    // A file's time is kept to the microsecond: near enough.
    #expect(abs((Artifacts.canvasTime(canvas.path, root: root.path) ?? 0) - (before + 5)) < 0.01)
    #expect(abs((Artifacts.items(root: root.path).first?.modified ?? 0) - (before + 5)) < 0.01)
}

/// What the host sends: the publishing lines alone, and with a time only those from the second after it on.
@Test func aHostSendsOnlyNewPublishingLines() throws {
    let file = tmp().appendingPathComponent("t.jsonl")
    try [
        #"{"timestamp":"2026-11-13T10:00:00.500Z","name":"mcp__claude-artifacts__publish_version"}"#,
        #"{"timestamp":"2026-11-13T10:00:01.000Z","text":"nothing published"}"#,
        #"{"timestamp":"2026-11-13T10:00:01.200Z","text":"https://claude.ai/artifact/x"}"#
    ].joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    func lines(_ since: Date?) throws -> Int {
        let out = try Subprocess.output(
            ["/bin/sh", "-c", "<" + ShellQuote.word(file.path) + " " + Artifacts.hostPublishes(since: since)], cwd: "/")
        return String(decoding: out, as: UTF8.self).split(separator: "\n").count
    }
    #expect(try lines(nil) == 2)
    #expect(try lines(try Date("2026-11-13T10:00:00Z", strategy: .iso8601)) == 1)
    #expect(try lines(try Date("2026-11-13T10:00:01Z", strategy: .iso8601)) == 0)
}

/// A mark goes to a chat with the page as the user saw it kept as a version, the chat may answer it, and the end of
/// the turn its prompt was about hands it back to the user with what the turn did to the marked thing.
@Test func marksComeBackToTheUserAfterTheTurnThatGotThem() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let root = try tempRoot()
    let canvas = try Artifacts.create(.design, title: "Home", root: root.path, session: "s1")
    try #"{"boards": [{"file": "boards/A.html"}, {"file": "boards/B.html"}]}"#.write(
        to: canvas, atomically: true, encoding: .utf8)
    let folder = canvas.deletingLastPathComponent()
    let a = folder.appendingPathComponent("boards/A.html"), b = folder.appendingPathComponent("boards/B.html")
    try #"<h1 data-id="title">Hi</h1><p data-id="cta">Start</p>"#.write(to: a, atomically: true, encoding: .utf8)
    try "<p>b</p>".write(to: b, atomically: true, encoding: .utf8)
    try Artifacts.keepVersions(root: root.path, session: "s1", label: "make it")
    let path = canvas.path, page = Artifacts.projectPath(path)
    // The window's two drafts and a hand edit the user made before sending.
    var marks = try ArtifactMarksChange(
        path: path,
        change: .drafts([
            ArtifactMark(board: "boards/A.html", target: "[data-id=title]", note: "bigger"),
            ArtifactMark(kind: .area, board: "boards/B.html", area: [0, 0, 10, 10], note: "a screen here")
        ])
    ).handle(NoService())
    #expect(marks.marks.map(\.id) == [1, 2])
    try #"<h1 data-id="title">Hi</h1><p data-id="cta">Go</p>"#.write(to: a, atomically: true, encoding: .utf8)
    _ = try ArtifactMarksChange(
        path: path,
        change: .edit(
            HandEdit(
                board: "boards/A.html", id: "cta", what: "text",
                from: "Start", to: "Go"))
    ).handle(NoService())
    marks = try ArtifactMarksChange(
        path: path, change: .send(ids: [1, 2], to: "s2", before: nil), pictures: ["2": Data([1, 2, 3])]
    ).handle(NoService())
    let versions = try #require(Artifacts.record(in: folder)?.versions)
    #expect(versions.map(\.n) == [1, 2] && versions[1].byUser == true && versions[1].label == "cta")
    #expect(marks.marks.allSatisfy { $0.state == .sent && $0.rounds.last?.before == 2 } && marks.edits.isEmpty)
    #expect(
        FileManager.default.contents(atPath: folder.appendingPathComponent("marks/2-1.png").path) == Data([1, 2, 3]))
    // An example picture given to #2 is kept beside its own, and named in the message.
    let example = try ArtifactMarksChange(path: path, change: .reference(id: 2), pictures: ["2": Data([4, 5])])
        .handle(NoService())
    #expect(example.marks.first { $0.id == 2 }?.reference == "marks/2-ref.png")
    #expect(FileManager.default.contents(atPath: folder.appendingPathComponent("marks/2-ref.png").path) == Data([4, 5]))
    #expect(Artifacts.items(root: root.path).first?.marks == ArtifactMarkCounts(sent: 2, check: 0))
    // The agent answers #2 through kelp; a mark that isn't there is refused.
    #expect(try await c.call(ArtifactReply(path: path, id: 2, text: "Which screen?")))
    await #expect(throws: RPCError.self) { try await c.call(ArtifactReply(path: path, id: 9, text: "?")) }
    // The chat works on the title only; a turn about something else leaves the marks with it.
    try #"<h1 data-id="title" style="font-size: 40px">Hi</h1><p data-id="cta">Go</p>"#.write(
        to: a, atomically: true, encoding: .utf8)
    try Artifacts.keepVersions(root: root.path, session: "s2", label: "fix the tests")
    try Artifacts.settleMarks(root: root.path, session: "s2", prompt: "fix the tests")
    #expect(ArtifactMarks.read(Artifacts.small(folder.appendingPathComponent("notes.json").path)).counts[.sent] == 2)
    try Artifacts.settleMarks(root: root.path, session: "s2", prompt: "Marks on \(page) (version 2)…")
    let back = ArtifactMarks.read(Artifacts.small(folder.appendingPathComponent("notes.json").path)).marks
    #expect(back.map(\.state) == [.check, .check])
    #expect(back.map { $0.rounds.last?.outcome } == [.changed, .same])
    #expect(back[1].rounds.last?.reply == "Which screen?" && back[0].rounds.last?.after == 3)
    // A pause in hand edits keeps them as the user's version, named by what they changed.
    try #"<h1 data-id="title" style="font-size: 48px">Hi</h1><p data-id="cta">Go</p>"#.write(
        to: a, atomically: true, encoding: .utf8)
    #expect(try ArtifactKeepVersion(path: path, label: "title").handle(NoService()))
    #expect(try !ArtifactKeepVersion(path: path, label: "title").handle(NoService()), "nothing new since")
    let last = try #require(Artifacts.record(in: folder)?.versions?.last)
    #expect((last.n, last.label, last.byUser) == (4, "title", true))
    // The agent asks about the title: a mark of its own, on the board that has it, for the user to answer; it suggests
    // what to ask next, until the user's next send.
    let asked = try ArtifactAsk(path: path, id: "title", text: "Bigger still?").handle(NoService())
    let withQuestion = ArtifactMarks.read(Artifacts.small(folder.appendingPathComponent("notes.json").path))
    #expect(
        withQuestion.marks.last.map { ($0.id, $0.board, $0.target, $0.asked, $0.state) }
            ?? (0, "", "", nil, .done) == (asked, "boards/A.html", "[data-id=title]", "Bigger still?", .draft))
    #expect(throws: RPCError.self) { try ArtifactAsk(path: path, id: "nothing", text: "?").handle(NoService()) }
    #expect(
        try ArtifactSuggest(path: path, lines: ["Dark version", " ", "Reviews", "More", "Fourth"]).handle(NoService()))
    #expect(
        ArtifactMarks.read(Artifacts.small(folder.appendingPathComponent("notes.json").path)).suggestions
            == ["Dark version", "Reviews", "More"])
    // Version 3 brought back is kept as a new version that says so, even when the page reads as the last one.
    #expect(try ArtifactKeepRestored(path: path, from: 3).handle(NoService()))
    let restored = try #require(Artifacts.record(in: folder)?.versions?.last)
    #expect((restored.n, restored.restored, restored.byUser) == (5, 3, true))
    // The user names it; a name of only spaces changes nothing.
    #expect(try ArtifactRename(path: path, title: "  Launch page ").handle(NoService()))
    #expect(Artifacts.record(in: folder)?.title == "Launch page")
    #expect(try !ArtifactRename(path: path, title: "   ").handle(NoService()))
}
