import AppKit
import Foundation
import Testing
import TestSupport
import Core
import WorkbenchKit
@testable import KelpApp
@testable import KelpKit
@testable import DesignKit
@testable import BuiltinAgents
@testable import BuiltinFiles
@testable import BuiltinGit
@testable import BuiltinBrowser
@testable import BuiltinIssues
@testable import BuiltinActivity

private func session(_ status: AgentStatus, unread: Bool = false, agent: String? = "claude", summary: String = "") -> Session {
    Session(cwd: "/", command: "x", agent: agent, status: status, unread: unread, summary: summary)
}

@MainActor @Test func quickOpenRanksPrefixThenWordThenContainsThenSeveralWords() {
    #expect(QuickOpen.wordScore("Open Settings", "open") == 100)
    #expect(QuickOpen.wordScore("Open Settings", "sett") == 80)       // starts a word
    #expect(QuickOpen.wordScore("Open Settings", "ttings") == 60)     // somewhere inside
    #expect(QuickOpen.wordScore("Open Recent Project", "pro rec") == 40)   // every word starts a word, in any order
    #expect(QuickOpen.wordScore("Open Settings", "xyz") == nil)
    #expect(QuickOpen.wordScore("Anything", "  ") == 0)               // an empty query matches everything equally
    #expect(QuickOpen.wordScore("OPEN", "open") == 100)               // case doesn't matter
}

/// A layout change still waiting out the save's pause is saved when the app quits, not lost with it.
@MainActor @Test func aLayoutChangedJustBeforeQuittingIsSaved() {
    let id = "quit-\(UUID().uuidString.prefix(6))", key = "layout/\(id)"
    let app = AppModel(builtins: Builtins.all)
    let area = EditorArea(app: app, workspaceId: id)
    area.scheduleSave()
    #expect(app.uiState[key] == nil)   // waiting
    EditorArea.saveLayouts()
    #expect(app.uiState[key] != nil)
}

/// Scored off the main thread: files by fuzzy path, the rest by title words (a command a little ahead), unmatched left out.
@Test func quickOpenScoresAQueryOffTheMainThread() async {
    let items = [QuickOpen.Match(fuzzy: nil, title: "Color Theme", command: false),
                 QuickOpen.Match(fuzzy: ProjectFiles.FuzzyPath("Sources/Settings/SettingsWindow.swift"), title: "SettingsWindow.swift", command: false),
                 QuickOpen.Match(fuzzy: nil, title: "Open Settings", command: true),
                 QuickOpen.Match(fuzzy: nil, title: "Settings: Font", command: false)]
    let best = await Task.detached { QuickOpen.best(items, "sett") }.value
    #expect(best == [1, 3, 2])
}

/// A peeking panel stays while the pointer crosses from the window's edge strip (4 pt) to the panel (6 pt in), and on
/// either side; it goes once the pointer is past the panel.
@MainActor @Test func aPeekingPanelStaysWhileThePointerCrossesTheGapFromTheEdge() {
    let edge = NSRect(x: 0, y: 0, width: 4, height: 800), panel = NSRect(x: 6, y: 6, width: 260, height: 788)
    #expect(MainWindowController.overPeek(NSPoint(x: 5, y: 400), panel: panel, edge: edge))   // the gap
    #expect(MainWindowController.overPeek(NSPoint(x: 2, y: 400), panel: panel, edge: edge))
    #expect(MainWindowController.overPeek(NSPoint(x: 100, y: 400), panel: panel, edge: edge))
    #expect(!MainWindowController.overPeek(NSPoint(x: 300, y: 400), panel: panel, edge: edge))
}

/// The context ring: nothing while there's room, then yellow, orange, red — by share in a 200k window, by tokens in 1M.
@MainActor @Test func theContextRingColoursAtTheTokensWhereAnswersSlip() {
    func level(_ used: Int, _ window: Int) -> Int { ContextMeter.level(SessionContextWindow.Usage(used: used, window: window)) }
    #expect([99_000, 100_000, 130_000, 150_000].map { level($0, 200_000) } == [0, 1, 2, 3])
    #expect([199_000, 200_000, 400_000, 600_000].map { level($0, 1_000_000) } == [0, 1, 2, 3])
    #expect(ContextMeter.level(nil) == 0 && level(5, 0) == 0)
}

/// ">" first in ⌘P turns it into ⇧⌘P, its "Commands ›" token in the field; ⌫ past the start goes back, as in VS Code.
@MainActor @Test func aGreaterThanSignTurnsOpenQuicklyIntoCommandsAndBackspaceTurnsItBack() {
    _ = testHome; _ = NSApplication.shared
    let q = QuickOpen(app: AppModel(builtins: Builtins.all))
    q.build()
    q.field.stringValue = ">new"
    q.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    #expect(q.commandsOnly && q.field.stringValue == "new" && q.field.scope == "Commands")
    q.field.stringValue = ""
    #expect(q.control(q.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.deleteBackward(_:))))
    #expect(!q.commandsOnly && q.field.scope == nil)
}

/// ⌘P's tabs say where they are in words: a file inside its workspace, a page's host, the changes; never their address.
@MainActor @Test func paletteTabsSayWhereTheyAre() {
    #expect(QuickOpen.place(TabURI.file("/w/Sources/App.swift"), root: "/w").detail == "Sources/App.swift")
    #expect(QuickOpen.place(TabURI.file(NSHomeDirectory() + "/notes.md"), root: "/w").detail == "~/notes.md")
    #expect(QuickOpen.place(TabURI.diff("w1"), root: "/w").detail == "Changes")
    #expect(QuickOpen.place("https://example.com/a/b", root: nil).detail == "example.com")
}

/// ⇧⌘P's empty list starts with what was run from it last, newest first; one the menus no longer offer drops out.
@MainActor @Test func commandsRunFromThePaletteComeBackFirst() {
    let saved = UserDefaults.standard.stringArray(forKey: QuickOpen.usedKey)
    defer { UserDefaults.standard.set(saved, forKey: QuickOpen.usedKey) }
    UserDefaults.standard.removeObject(forKey: QuickOpen.usedKey)
    func item(_ title: String, _ kind: String = "Command") -> QuickOpen.Item {
        QuickOpen.Item(kind: kind, icon: "", title: title, detail: "File", action: {})
    }
    let pool = [item("New Workspace"), item("Close Tab"), item("Appearance: Color Theme", "Setting"), item("Reload")]
    for t in ["Close Tab", "New Workspace", "Close Tab"] { QuickOpen.remember(item(t)) }
    QuickOpen.remember(item("Appearance: Color Theme", "Setting"))
    QuickOpen.remember(item("Open Quickly", "File"))   // not a command: not kept
    QuickOpen.remember(item("Gone"))
    let used = QuickOpen.recentlyUsed(pool)
    #expect(used.map(\.title) == ["Appearance: Color Theme", "Close Tab", "New Workspace"])
    #expect(used.allSatisfy { $0.recent })
}

@MainActor @Test func notificationsReadTheFirstSentenceAsAHeadline() {
    #expect(Notifier.firstSentence("I added `mul(a, b)` to `calc.py`. It returns the product.") == "Added mul(a, b) to calc.py")
    #expect(Notifier.firstSentence("I've fixed the login bug!\nMore detail below.") == "Fixed the login bug!")
    #expect(Notifier.firstSentence("Done") == "Done")
    let long = String(repeating: "word ", count: 40)
    let cut = Notifier.firstSentence(long)
    #expect(cut.count == 90 && cut.hasSuffix("…"))   // long text is cut to fit a banner
}

@MainActor @Test func onlyAWaitingAgentAsksForPermission() {
    #expect(Notifier.asksPermission(session(.waiting, summary: "Claude needs your permission to use Bash")))
    #expect(Notifier.asksPermission(session(.waiting, summary: "Allow rm -rf build?")))
    #expect(!Notifier.asksPermission(session(.working, summary: "needs your permission")))   // not waiting any more
    #expect(!Notifier.asksPermission(session(.waiting, summary: "Which file should I edit?")))
}

/// A limit that ran out: when it resets, the sessions that stopped at it, not one that went on by itself or ended before.
@Test func aLimitResetFindsTheSessionsItStopped() throws {
    let now = Date(), until = now.addingTimeInterval(3600)
    func reading(_ p: Double, _ at: Date?) -> (agent: String, limit: UsageGet.Limit, resetAt: Date?) { ("codex", .init(kind: "session", percent: p, resets: nil), at) }
    var r = LimitResets()
    #expect(r.update([reading(80, until)], now: now).isEmpty)
    #expect(r.update([reading(100, until)], now: now) == ["codex"])
    #expect(r.update([reading(100, until)], now: now).isEmpty)   // told once
    #expect(r.update([reading(100, until.addingTimeInterval(60))], now: now) == ["codex"])   // a later reset
    let f = try #require(r.full["codex"])
    func s(_ status: AgentStatus, _ at: TimeInterval, agent: String = "codex") -> Session {
        var x = session(status, agent: agent); x.statusAt = now.addingTimeInterval(at); return x
    }
    let stoppedAtIt = s(.done, 5), wentOn = s(.working, 3700), before = s(.done, -600), other = s(.done, 5, agent: "claude")
    #expect(LimitResets.stopped([stoppedAtIt, wentOn, before, other], agent: "codex", f).map(\.id) == [stoppedAtIt.id])
    #expect(r.end("codex") != nil && r.full.isEmpty)
}

@MainActor @Test func aBannerAnswersAPermissionOrTakesAReply() {
    #expect(Notifier.category(session(.waiting, summary: "Allow npm test?")) == "permission")
    #expect(Notifier.category(session(.done, summary: "Added the login form")) == "reply")
    #expect(Notifier.category(session(.error)) == "reply")
    #expect(Notifier.category(session(.waiting, summary: "Which file should I edit?")) == nil)   // its own menu answers it
}

@MainActor @Test func theSidebarFlagsWhatWantsYou() {
    #expect(SidebarCell.wantsYou(session(.waiting)))
    #expect(SidebarCell.wantsYou(session(.error)))
    #expect(SidebarCell.wantsYou(session(.done, unread: true)))
    #expect(!SidebarCell.wantsYou(session(.done, unread: false)))   // seen
    #expect(!SidebarCell.wantsYou(session(.waiting, agent: "shell")))   // a plain terminal never asks
    #expect(SidebarCell.wantsYou(session(.hibernated, unread: true)))   // paused, but it finished and you haven't looked
    #expect(!SidebarCell.wantsYou(session(.hibernated)))
    #expect(SidebarCell.isNews(session(.done, unread: true)) && !SidebarCell.isNews(session(.idle, unread: true)) && !SidebarCell.isNews(session(.done)))
    #expect(SidebarCell.isNews(session(.hibernated, unread: true)))   // bold as long as it's counted
}

@MainActor @Test func aProjectTileShowsTheInitialsOfItsFirstTwoWords() {
    #expect(IconTile.initials("AgroStorage") == "AS" && IconTile.initials("AgroTrack") == "AT")   // apart, though both start with A
    #expect(IconTile.initials("kelp-extensions") == "KE" && IconTile.initials("x_post") == "XP")
    #expect(IconTile.initials("vangersert") == "V" && IconTile.initials("Area69-0.83-pc") == "AP")   // words that start with a letter
    #expect(IconTile.initials("2024") == "2" && IconTile.initials("") == "?")
}

@MainActor @Test func aRowShortensTensOfThousandsOfChangedLines() {
    #expect(RowBadges.changes(added: 21670, removed: 0, compact: true).string == "+21.7k")   // generated files: not wider than the name
    #expect(RowBadges.changes(added: 10000, removed: 3, compact: true).string == "+10k −3")
    #expect(RowBadges.changes(added: 9999, removed: 0, compact: true).string == "+9999")
    #expect(RowBadges.changes(added: 21670, removed: 0).string == "+21670")   // a diff's header keeps the count
}

@MainActor @Test func anAgentThatNeedsYouSaysWhatUnderItsName() {
    let ask = SidebarCell.askLine(session(.waiting, summary: "May I run npm test?"), mode: "needsYou")
    #expect(ask?.prefix?.0 == "Asks:" && ask?.text == "May I run npm test?")
    #expect(SidebarCell.askLine(session(.error), mode: "needsYou")?.prefix?.0 == "Failed:")       // no summary: its state in words
    #expect(SidebarCell.askLine(session(.working, summary: "Editing"), mode: "needsYou") == nil)   // one line unless it needs you
    #expect(SidebarCell.askLine(session(.working, summary: "Editing"), mode: "always")?.text == "Editing")
    #expect(SidebarCell.askLine(session(.waiting, summary: "May I?"), mode: "never") == nil)
}

@MainActor @Test func activityNumbersAndPercentagesAreReadable() {
    #expect(ActivityController.percent(0) == "0.0%" && ActivityController.percent(9.94) == "9.9%")
    #expect(ActivityController.percent(10) == "10%" && ActivityController.percent(99.6) == "100%")   // from 10 up no decimals
}

@MainActor @Test func shortcutsShowTheWayMenusDo() {
    func d(_ key: String, _ mods: KeySpec.Modifiers) -> String { KeyBindings.display(KeySpec(key: key, mods: mods)) }
    #expect(d("k", [.shift, .command]) == "⇧⌘K")
    #expect(d("k", [.control, .option, .shift, .command]) == "⌃⌥⇧⌘K")   // the order macOS uses
    #expect(d("\r", [.command]) == "⌘↩" && d("\u{F700}", [.option]) == "⌥↑" && d("\u{7f}", [.command]) == "⌘⌫")
}

@MainActor @Test func aDotInsideAFileNameDoesNotEndTheHeadline() {
    #expect(Notifier.firstSentence("Updated README.md and docs/arch.md. Tests pass.") == "Updated README.md and docs/arch.md")
    #expect(Notifier.firstSentence("Is v1.2 ready? Yes.") == "Is v1.2 ready?")
    #expect(Notifier.firstSentence("Fixed it.") == "Fixed it")
}

/// Build output never reaches a watcher's handler (it's dropped off the main thread); other changes arrive on main.
@MainActor @Test func fileEventsSkipBuildOutput() async throws {
    #expect(FileWatcher.isBuildOutput("/r/node_modules/a/b.js", under: ["/r/"]))
    #expect(!FileWatcher.isBuildOutput("/work/target/r/src/a.rs", under: ["/work/target/r/"]))   // the root's own folders don't count
    #expect(!FileWatcher.isBuildOutput("/elsewhere/.build/x", under: ["/r/"]))
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-fw-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("node_modules/x"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    var seen: [String] = []
    let w = FileWatcher(root: dir.path, latency: 0.05) { paths in MainActor.assumeIsolated { seen += paths } }
    try Data("a".utf8).write(to: dir.appendingPathComponent("node_modules/x/a.js"))
    try Data("b".utf8).write(to: dir.appendingPathComponent("b.swift"))
    for _ in 0..<60 where !seen.contains(where: { $0.hasSuffix("/b.swift") }) { try await Task.sleep(for: .milliseconds(50)) }
    #expect(w != nil && seen.contains { $0.hasSuffix("/b.swift") })
    #expect(!seen.contains { $0.contains("/node_modules/") })
}

/// One way to run a program, through the daemon: its code and output, stdin, a timeout that kills it, a launch that
/// fails; and none at all without a daemon.
extension OneAtATime {
@Test func shellExecRunsAndKills() async throws {
    let rig = try await AppRig(files: [:]); defer { rig.done() }
    let echo = await Shell.exec(rig.app, ["/bin/cat"], input: "hi")
    #expect(echo.code == 0 && echo.stdout == "hi")
    #expect(await Shell.exec(rig.app, ["/bin/sh", "-c", "echo e >&2; exit 3"]).code == 3)
    let t = Date(), slow = await Shell.exec(rig.app, ["/bin/sleep", "5"], timeout: 0.2)
    #expect(slow.code != 0 && Date().timeIntervalSince(t) < 2)
    #expect(await Shell.exec(rig.app, ["/nonexistent/tool"]).code == -1)
    // Where a tool is comes from the daemon's login-shell PATH: the app doesn't start a shell to read it.
    let paths = try await rig.app.get(ProcessWhich(commands: ["git", "kelp-no-such-agent"]))
    #expect(paths["git"]?.hasSuffix("/git") == true && paths["kelp-no-such-agent"] == nil)
    #expect(await AgentAvailability.runs(try #require(paths["git"]), app: rig.app) != nil)
    #expect(await AgentAvailability.runs("/nonexistent/agent", app: rig.app) == nil)
    rig.app.client = nil
    #expect(await Shell.exec(rig.app, ["/bin/echo", "hi"]).code == -1)   // the app runs nothing itself
}

/// An agent CLI that answered `--version` in the last day isn't started again until it changes.
@Test func agentThatRanIsNotStartedAgain() async throws {
    let rig = try await AppRig(files: [:]); defer { rig.done() }
    let dir = tmp(), log = dir.appendingPathComponent("log"), cli = dir.appendingPathComponent("agent").path
    func write(_ body: String) throws {
        try "#!/bin/sh\necho >> '\(log.path)'\n\(body)\n".write(toFile: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli)
    }
    func starts() -> Int { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").count }
    try write("exit 0")
    let binary = try #require(await AgentAvailability.runs(cli, app: rig.app))
    let now = Date().timeIntervalSince1970
    #expect(await AgentAvailability.runs(cli, ran: [binary: now], app: rig.app) == binary && starts() == 1)   // remembered
    #expect(await AgentAvailability.runs(cli, ran: [binary: now - 2 * 86400], app: rig.app) == binary && starts() == 2)   // a day on: asked again
    try write("exit 1")   // updated, and broken now
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: cli)
    #expect(await AgentAvailability.runs(cli, ran: [binary: now], app: rig.app) == nil && starts() == 3)
}
}

/// A burst of calls runs once, the last one, after the pause; cancel drops it.
@MainActor @Test func debounceRunsTheLastCallOnce() async throws {
    let d = Debounce()
    var ran: [Int] = []
    for i in 1...3 { d.after(0.05) { ran.append(i) } }
    // A control scheduled after the burst, with a longer delay: once it ran, any other call of the burst would have too.
    let after = Debounce(); var settled = false
    after.after(0.1) { settled = true }
    for _ in 0..<100 where !settled { try await Task.sleep(for: .milliseconds(50)) }   // however busy the Mac
    #expect(ran == [3])
    d.after(0.05) { ran.append(4) }; d.cancel()
    let later = Debounce(); var control = false
    later.after(0.1) { control = true }   // scheduled after the cancelled one, with a longer delay: once it ran, the other would have
    for _ in 0..<100 where !control { try await Task.sleep(for: .milliseconds(50)) }
    #expect(control && ran == [3])
}

@MainActor @Test func theTrustSheetShowsEverythingTrustAllows() throws {
    let info = ScriptsList.Result(scripts: [.init(name: "test", command: "npm test")], setup: "npm i", tabs: ["claude"], shared: ["node_modules"],
                                  recipes: ["commit": "also run x"], issueCommand: "Fix {title}", digest: "", trusted: false, file: "")
    let scroll = try #require(ScriptsMenu.trustText(info) as? NSScrollView)
    let text = try #require(scroll.documentView as? NSTextView).string
    for line in ["setup: npm i", "test: npm test", "tabs: claude", "shared: node_modules", "issueCommand: Fix {title}", "recipe.commit: also run x"] {
        #expect(text.contains(line), "\(line) is missing from the sheet")
    }
}

/// When kelpd doesn't answer, the banner says why it didn't start (what it left in kelpd.err) and the fix when one is
/// known, not only that it isn't running.
@MainActor @Test func theNoServiceBannerSaysWhyTheDaemonDidntStart() throws {
    let root = tmp()
    #expect(AppModel.whyNoService(root: root) == AppModel.noService)   // nothing left: nothing to add
    try "xcrun: error: invalid active developer path\n".write(to: Paths.daemonError(in: root), atomically: true, encoding: .utf8)
    let said = AppModel.whyNoService(root: root)
    #expect(said.hasPrefix(AppModel.noService) && said.contains("invalid active developer path") && said.contains("xcode-select --install"))
}

/// An extension's page stays its own: the bridge and what it's handed (settings, the workspace's path) never reach a site
/// or a file the extension didn't ship that a link or a script took the window to.
@Test @MainActor func anExtensionsWindowStaysOnItsOwnPages() {
    let folder = URL(fileURLWithPath: "/tmp/ext/board")
    #expect(ExtWebController.isOwn(URL(fileURLWithPath: "/tmp/ext/board/index.html"), folder))
    #expect(ExtWebController.isOwn(URL(fileURLWithPath: "/tmp/ext/board/pages/b.html"), folder))
    #expect(!ExtWebController.isOwn(URL(string: "https://example.com/index.html")!, folder))
    #expect(!ExtWebController.isOwn(URL(fileURLWithPath: "/tmp/ext/board-evil/index.html"), folder))
    #expect(!ExtWebController.isOwn(URL(fileURLWithPath: "/tmp/ext/board/../other/index.html"), folder))
    #expect(!ExtWebController.isOwn(URL(fileURLWithPath: "/tmp/ext/board"), folder))
}

/// Restart Background Service with a kelpd that doesn't answer (stopped here): it's ended by its pid, and a pid that
/// isn't kelpd's is left alone.
@Test func aHungDaemonIsStoppedByItsPid() async throws {
    let kelp = try #require(ProcessInfo.processInfo.environment["KELP_TRAMPOLINE"])
    let d = Process(), other = Process()
    d.executableURL = URL(fileURLWithPath: kelp).deletingLastPathComponent().appendingPathComponent("kelpd")
    d.environment = ProcessInfo.processInfo.environment.merging(["KELP_HOME": tmp().path]) { $1 }
    other.executableURL = URL(fileURLWithPath: "/bin/sleep"); other.arguments = ["30"]
    try d.run(); try other.run()
    defer { for p in [d, other] where p.isRunning { p.terminate() } }   // only what this test started
    kill(d.processIdentifier, SIGSTOP)
    await AppModel.stop(other.processIdentifier)
    #expect(other.isRunning)
    await AppModel.stop(d.processIdentifier)
    for _ in 0..<50 where d.isRunning { try await Task.sleep(for: .milliseconds(100)) }
    #expect(!d.isRunning && d.terminationReason == .uncaughtSignal)
}

/// The glow's frame is a band with a hole under either fill rule: the shadow path is filled non-zero, and a hole that
/// filled in would glow over the whole pane.
@MainActor @Test func theGlowsFrameHasAHoleUnderTheShadowsRule() {
    // A pane's square-ish corners and a tab's capsule alike: the middle is never part of the light.
    for (rect, r) in [(CGRect(x: 0, y: 0, width: 200, height: 100), 6.0), (CGRect(x: 0, y: 0, width: 160, height: 28), 14.0)] {
        let p = EdgeGlow.frame(around: rect, radius: r)
        #expect(!p.contains(CGPoint(x: rect.midX, y: rect.midY), using: .winding) && !p.contains(CGPoint(x: rect.midX, y: rect.midY), using: .evenOdd))
        #expect(p.contains(CGPoint(x: -10, y: rect.midY), using: .winding))
    }
}

@Test func limitAlertsFireOncePerLevel() {
    func u(_ p: Double) -> UsageGet.Result { .init(claude: [], codex: [], plans: ["grok": [.init(kind: "week", percent: p, resets: "Sat")]]) }
    var a = LimitAlerts()
    #expect(a.update(u(85)).isEmpty)                 // baseline: already full at launch
    #expect(a.update(u(90)).isEmpty)
    #expect(a.update(u(96)).map(\.level) == [95])
    #expect(a.update(u(99)).isEmpty)
    #expect(a.update(u(10)).isEmpty)                 // window reset
    #expect(a.update(u(81)).map(\.level) == [80])
}

@Test func limitAlertsFollowTheChosenLevel() {
    func u(_ p: Double) -> UsageGet.Result { .init(claude: [], codex: [], plans: ["grok": [.init(kind: "week", percent: p, resets: nil)]]) }
    var a = LimitAlerts()
    #expect(a.update(u(50), first: 70).isEmpty)
    #expect(a.update(u(72), first: 70).map(\.level) == [70])
    #expect(a.update(u(99), first: nil).isEmpty)     // off
    #expect(LimitAlerts.levels(first: 95) == [95])
}

@Test func staleLimitReadingsDontAlert() {
    let now = Date()
    func u(_ ago: Double) -> UsageGet.Result {
        .init(claude: [], codex: [], plans: ["grok": [.init(kind: "week", percent: 99, resets: nil)]],
              plansReadAt: ["grok": now.timeIntervalSince1970 - ago])
    }
    #expect(LimitAlerts.readings(u(60), now: now).count == 1)
    #expect(LimitAlerts.readings(u(7200), now: now).isEmpty)
}

@Test func limitForecastWarnsOnlyWhenItFillsBeforeItResets() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func u(_ p: Double) -> UsageGet.Result { .init(claude: [], codex: [], plans: ["grok": [.init(kind: "session", percent: p, resets: "in 4h")]]) }
    var f = LimitForecast()
    let key = LimitForecast.key("grok", "session")
    f.record(u(20), now: t0)
    #expect(f.untilFull(key, now: t0) == nil)                                 // one reading tells no pace
    f.record(u(30), now: t0.addingTimeInterval(600))                          // 1 point a minute
    let now = t0.addingTimeInterval(600)
    #expect(abs((f.untilFull(key, now: now) ?? 0) - 70 * 60) < 1)
    #expect(f.warning(key, resetAt: now.addingTimeInterval(4 * 3600), now: now) != nil)   // full in 70 min, resets in 4 h
    #expect(f.warning(key, resetAt: now.addingTimeInterval(3600), now: now) == nil)       // resets first
    f.record(u(5), now: t0.addingTimeInterval(1500))                          // the window reset
    #expect(f.untilFull(key, now: t0.addingTimeInterval(1500)) == nil)
}

@Test func resetTimesParse() {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 1_792_000_000)   // 2026-10-14 17:46 UTC
    #expect(ResetTime.parse("in 1h 30m", now: now, calendar: cal) == now.addingTimeInterval(5400))
    #expect(ResetTime.parse("in 3d", now: now, calendar: cal) == now.addingTimeInterval(3 * 86400))
    let three = ResetTime.parse("3pm", now: now, calendar: cal)
    #expect(three.map { cal.component(.hour, from: $0) } == 15 && three! > now)
    #expect(ResetTime.parse("7:40am", now: now, calendar: cal).map { cal.component(.minute, from: $0) } == 40)
    #expect(ResetTime.parse("Oct 20 at 5am", now: now, calendar: cal).map { cal.component(.day, from: $0) } == 20)
    #expect(ResetTime.parse("Nov 23", now: now, calendar: cal).map { cal.component(.month, from: $0) } == 11)
    #expect(ResetTime.parse("soon", now: now, calendar: cal) == nil)
}
