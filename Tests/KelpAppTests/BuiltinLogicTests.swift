import AppKit
import Foundation
import JavaScriptCore
import Testing
import Core
@testable import KelpKit
@testable import BuiltinActivity
@testable import BuiltinBrowser
@testable import BuiltinFiles
@testable import BuiltinIssues

/// The built-ins' small decisions, without a window: how they word and sort what they show.

@MainActor @Test func activityShowsCPUAsItReads() {
    #expect(ActivityController.percent(3.25) == "3.2%" || ActivityController.percent(3.25) == "3.3%")
    #expect(ActivityController.percent(42.6) == "43%")
}

@MainActor @Test func anUntitledFileIsNamedAfterItsFirstLine() {
    #expect(UntitledTab.suggestedName("def main():\n    pass") == "def main()")
    #expect(UntitledTab.suggestedName("a/b:c*d?\nrest") == "abcd")
    #expect(UntitledTab.suggestedName("\n\nlater") == "later")   // the first line with text
    #expect(UntitledTab.suggestedName("  \n") == nil)
    #expect(UntitledTab.suggestedName(String(repeating: "x", count: 100))?.count == 40)
}

@MainActor @Test func theFileTreeHasFoldersFirstAndMarksWhatGitIgnores() {
    let tree = FileNode.tree(["b.txt", "src/main.swift", "a.txt"], ignored: [".build/"])
    #expect(tree.map(\.name) == [".build", "src", "a.txt", "b.txt"])
    #expect(tree.first?.ignored == true && tree.first { $0.name == "src" }?.ignored == false)
    #expect(FileNode.find("src/main.swift", in: tree)?.path == "src/main.swift")
    #expect(FileNode.find("src/nope.swift", in: tree) == nil)
}

@MainActor @Test func aPullRequestsChecksReadFailingFirst() {
    #expect(TasksViewController.checksText(.init(passed: 3, failed: 1, pending: 2)).contains("1 failing"))
    #expect(TasksViewController.checksText(.init(passed: 3, pending: 2)).contains("2 pending"))
    #expect(TasksViewController.checksText(.init(passed: 3)).contains("passed"))
    #expect(TasksViewController.checksText(.init()) == "")
}

@MainActor @Test func aMissingOrSignedOutCLISaysHowToFixIt() {
    #expect(Forge.setup(for: "gh: command not found")?.command == "brew install gh && gh auth login")
    #expect(Forge.setup(for: "You are not logged into any GitHub hosts")?.command == "gh auth login")
    #expect(Forge.setup(for: "could not resolve host github.com") == nil)
}

@MainActor @Test func aFileThatCantOpenSaysWhy() {
    #expect(FileTab.reason(.binary).contains("Binary"))
    #expect(FileTab.reason(.tooBig(60 << 20)).contains("Too big"))
    #expect(FileTab.reason(.special).contains("devices"))
}

@MainActor @Test func aCIRunReadsAsItsStatus() {
    #expect(CIRunLook.words("completed", "success") == "Succeeded")
    #expect(CIRunLook.words("completed", "failure") == "Failed")
    #expect(CIRunLook.words("in_progress", nil) == "Running")
    #expect(CIRunLook.words("queued", nil) == "Queued")
    #expect(CIRunLook.ago("not a date").isEmpty)
}

/// Design Mode's overlay is one script the page runs: a line break inside one of its strings (d4ca506 split the tag's
/// style over lines) made all of it a syntax error, and Design Mode drew nothing.
@MainActor @Test func designModesScriptParses() throws {
    let js = BrowserTab.designJS(accent: .systemBlue)
    #expect(!js.contains("ACCENT"))
    let context = try #require(JSContext())
    let literal = String(data: try JSONSerialization.data(withJSONObject: [js]), encoding: .utf8) ?? "[]"
    context.evaluateScript("new Function(\(literal)[0])")   // parses it without running it (no page here)
    #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
}

/// A long review thread reaches the agent as at most 12 comments of 800 characters, the rest counted.
@Test @MainActor func reviewCommentsForAnAgentAreCapped() {
    let long = String(repeating: "x", count: 2000)
    let cs = (1...15).map { GitHub.ReviewComment(path: "a.swift", line: $0, body: long, author: "amy", url: nil) }
    let text = TasksViewController.forAgent(cs)
    #expect(text.contains("12. a.swift:12 (amy)") && !text.contains("13. a.swift"))
    #expect(text.hasSuffix("(3 more comments omitted.)") && text.count < 12 * 830 + 40)
}

/// Why a pull request can't merge yet is said in words, the review or the checks named when GitHub only says BLOCKED.
@Test @MainActor func aBlockedMergeSaysWhy() {
    var pr = GitHub.PullRequest(number: 1, title: "T", url: "", author: "a", headRefName: "b", isDraft: false, state: "OPEN",
                                reviewDecision: "REVIEW_REQUIRED", checks: .init(failed: 1))
    #expect(TasksViewController.mergeBlock(pr) == nil)   // GitHub hasn't said
    pr.mergeState = "BLOCKED"
    #expect(TasksViewController.mergeBlock(pr) == "It needs an approving review.")
    pr.reviewDecision = "APPROVED"
    #expect(TasksViewController.mergeBlock(pr) == "Required checks failed.")
    pr.mergeState = "DIRTY"
    #expect(TasksViewController.mergeBlock(pr)?.contains("conflicts") == true)
    pr.mergeState = "CLEAN"
    #expect(TasksViewController.mergeBlock(pr) == nil)
}

/// A status read off the screen looks like a guess: a ring of dashes, and says so.
@Test @MainActor func aGuessedStatusSaysSo() {
    let mark = StatusMark()
    mark.status = .working
    mark.guessed = true
    #expect(mark.toolTip == "Working, as far as the screen shows")
    mark.guessed = false
    #expect(mark.toolTip == AgentStatus.working.words)
}

/// A parked agent comes back by itself when it asks, saying why; until then its Done doesn't call.
@Test @MainActor func aParkedAgentComesBackWhenItAsks() async throws {
    let rig = try await AppRig(files: ["a.txt": "a\n"]); defer { rig.done() }
    let m = rig.app
    var s = Session(worktreeId: rig.workspace.id, cwd: rig.repo, command: "claude", agent: "claude", status: .working)
    m.upsert(s)
    m.park(s.id, until: Mutes.forever)
    #expect(m.isParked(s.id) && m.parkedIds == [s.id])
    s.status = .waiting
    m.followParked(s)
    #expect(!m.isParked(s.id) && m.parkedBack[s.id] == "it asks you something")
    m.park(s.id, until: Date().addingTimeInterval(-1))   // a time that passed counts no more
    #expect(!m.isParked(s.id))
}

/// New Chat on Branch…: each mode asks the daemon for its own kind of folder.
@Test @MainActor func theNewChatSheetAsksForWhatWasPicked() {
    var c = NewChatSheet.Choice(mode: .new, name: "Fix login", from: "dev", branch: nil, pr: nil, agent: "codex")
    var r = NewChatSheet.request(c, repo: "r")
    #expect(r.note == "Fix login" && r.base == "dev" && r.branch == nil && r.existing == nil)
    c.mode = .existing; c.branch = "origin/spike"
    r = NewChatSheet.request(c, repo: "r")
    #expect(r.branch == "origin/spike" && r.existing == true)
    c.mode = .pullRequest; c.branch = "fix/flaky"; c.pr = 212
    r = NewChatSheet.request(c, repo: "r")
    #expect(r.pr == 212 && r.branch == "fix/flaky")
    let sheet = NewChatSheet(local: ["main"], remote: [], base: "main", prs: [], agents: [(id: "codex", name: "Codex")], picked: "codex")
    #expect(sheet.choice.mode == .new && sheet.choice.agent == "codex" && sheet.choice.from == "main")
}

/// With Increase Contrast Kelp's grey fills are twice as strong, as the system's own get; without it they're as before.
@Test @MainActor func fillsGetStrongerWithIncreaseContrast() {
    #expect(NSColor.fillAlpha(0.05, highContrast: true) == 0.10 && NSColor.fillAlpha(0.05, highContrast: false) == 0.05)
    var rest: CGFloat = 0
    NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { rest = NSColor.fillRest.usingColorSpace(.sRGB)?.alphaComponent ?? 0 }
    #expect(abs(rest - NSColor.fillAlpha(0.05, highContrast: NSColor.increaseContrast)) < 0.001)
}

/// A finished agent is read only with someone there: input in the last three minutes and the screen unlocked; unknown is away.
@Test func readingNeedsSomeoneThere() {
    #expect(Presence.decide(idle: 12, locked: false))
    #expect(!Presence.decide(idle: 12, locked: true))
    #expect(!Presence.decide(idle: 600, locked: false))
    #expect(!Presence.decide(idle: nil, locked: false) && !Presence.decide(idle: 12, locked: nil))
}

/// An extension.json broken while it's edited keeps the version that last loaded, its error beside it.
@Test @MainActor func aBrokenManifestKeepsTheLastOneThatWorked() async throws {
    let rig = try await AppRig(files: ["a.txt": "a\n"]); defer { rig.done() }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("extension.json")
    try #"{"id":"keep.me","name":"Keep","contributes":{"commands":[{"title":"Hi","run":"echo hi"}]}}"#.write(to: file, atomically: true, encoding: .utf8)
    let good = DeclarativeExtension.load(dir, app: rig.app)
    #expect(good.info.error == nil && good.contributions.commands.count == 1)
    try #"{"id":"keep.me","name":"Keep","contributes":{"commands":[{"title":"Hi","run":"echo hi"}"#.write(to: file, atomically: true, encoding: .utf8)
    let broken = DeclarativeExtension.load(dir, app: rig.app)
    #expect(broken.info.id == "keep.me" && broken.contributions.commands.count == 1)
    #expect(broken.info.error?.contains("Still running the version from before the change.") == true)
}

/// The library lists what it reviewed apart from what GitHub has under the topic, those fastest growing first.
@Test @MainActor func theLibraryKeepsTheUnreviewedApart() {
    func e(_ id: String, reviewed: Bool? = nil, weekly: Int? = nil) -> ExtensionLibrary.Entry {
        var x = ExtensionLibrary.Entry(id: id, name: id, version: "1", source: "o/\(id)")
        x.reviewed = reviewed; x.weekly = weekly; x.stars = weekly.map { $0 * 3 }
        return x
    }
    let (reviewed, found) = LibrarySection.split([e("a"), e("slow", reviewed: false, weekly: 2), e("b", reviewed: true), e("fast", reviewed: false, weekly: 40)])
    #expect(reviewed.map(\.id) == ["a", "b"] && found.map(\.id) == ["fast", "slow"])
}

/// A park for a while ends on screen when its time is up: the sidebar follows `parked`, which changes then by itself.
@Test @MainActor func aTimedParkEndsOnTime() async throws {
    let m = AppModel()
    m.park("s1", until: Date().addingTimeInterval(0.3))
    #expect(m.parked["s1"] != nil)
    for _ in 0..<40 where m.parked["s1"] != nil { try await Task.sleep(for: .milliseconds(50)) }
    #expect(m.parked["s1"] == nil)
}

/// The Issues panel shows the list last asked for: the slower reply of a filter left behind (All open, then Mine) used
/// to land over it, since only the project and the source were checked.
@MainActor @Test func theIssuesPanelShowsTheFilterLastPicked() async throws {
    let path = NSTemporaryDirectory() + "kelp-issues-\(getpid()).sock"
    let server = try Unix.listen(path)
    defer { close(server); unlink(path) }
    // A daemon whose "open" list answers late, the rest at once (an error for what isn't a list).
    Thread.detachNewThread {
        let fd = accept(server, nil, nil)
        var lines = LineBuffer(), buf = [UInt8](repeating: 0, count: 65536)
        while case let n = read(fd, &buf, buf.count), n > 0 {
            for line in lines.append(Data(buf[0..<n])) {
                guard let m = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = m["id"] as? Int else { continue }
                let late = (m["params"] as? [String: Any])?["filter"] as? String == "open"
                let pr = #"{"number":\#(late ? 1 : 2),"title":"t","url":"","author":"a","headRefName":"b","isDraft":false,"state":"OPEN","checks":{"passed":0,"failed":0,"pending":0}}"#
                let reply = m["method"] as? String == "github.prs" ? #"{"jsonrpc":"2.0","id":\#(id),"result":[\#(pr)]}"#
                    : #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32601,"message":"no"}}"#
                DispatchQueue.global().asyncAfter(deadline: .now() + (late ? 0.3 : 0)) { _ = Unix.writeAll(fd, Data((reply + "\n").utf8)) }
            }
        }
    }
    let m = AppModel(builtins: [])
    m.client = try RPCClient(socket: path)
    m.repos = [Repo(id: "r1", name: "one", path: "/one")]
    let panel = TasksViewController(app: m)
    panel.show(worktree: nil)
    _ = panel.view   // asks for All open
    panel.filter.selectItem(at: 1)
    panel.reload()   // then Mine
    try await Task.sleep(for: .milliseconds(600))
    guard case .pr(let shown)? = panel.rows.first else { Issue.record("no rows"); return }
    #expect(panel.rows.count == 1 && shown.number == 2)
}

/// What tells a refresh's lists from newer events is let go of as each refresh ends: it kept every record that ever was.
@MainActor @Test func eventCountsGoWithTheRefreshTheyServed() async {
    let m = AppModel(builtins: [])
    m.handle(Session(id: "s1", cwd: "/", command: "claude", agent: "claude", status: .working))
    m.handle(Repo(id: "r1", name: "one", path: "/one"))
    m.handle(RemovedEvent(repo: "r1", session: "s1"))
    #expect(!m.sessionEvents.isEmpty && !m.recordEvents.isEmpty)
    await m.refresh()
    #expect(m.sessionEvents.isEmpty && m.recordEvents.isEmpty)
}
