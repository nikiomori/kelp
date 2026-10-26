import AppKit
import Foundation
import Testing
import WorkbenchKit
@testable import KelpApp
@testable import KelpKit
@testable import BuiltinAgents
@testable import BuiltinFiles
@testable import BuiltinGit
@testable import BuiltinBrowser
@testable import BuiltinIssues
@testable import BuiltinActivity

/// A project's icon is looked for off the main thread: its initial shows at once, the icon once it's found.
@MainActor @Test func aProjectsIconIsFoundOffTheMainThread() async throws {
    let dir = testHome + "/icon-\(UUID().uuidString.prefix(6))"
    try FileManager.default.createDirectory(atPath: dir + "/public", withIntermediateDirectories: true)
    let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><circle cx="16" cy="16" r="10" fill="red"/></svg>"#
    try svg.write(toFile: dir + "/public/favicon.svg", atomically: true, encoding: .utf8)
    let view = NSImageView(), app = AppModel(builtins: Builtins.all)
    ProjectIcon.show(dir, in: view, app: app)
    let initial = try #require(view.image)
    for _ in 0..<100 where view.image === initial { try await Task.sleep(for: .milliseconds(20)) }
    #expect(view.image !== initial && view.image?.size == NSSize(width: 32, height: 32))
    #expect(ProjectIcon.image(for: dir, app: app) === view.image)   // found once
}

@Test func agesAreAsShortAsARowAllows() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func ago(_ s: Double) -> String { shortAgo(now.addingTimeInterval(-s), now: now) }
    #expect(ago(5) == "now" && ago(59) == "now")
    #expect(ago(60) == "1m" && ago(3599) == "59m")
    #expect(ago(3600) == "1h" && ago(82799) == "23h" && ago(86399) == "1d")   // the one part shown is rounded
    #expect(ago(86400 * 3) == "3d")
    #expect(shortAgo(now.addingTimeInterval(60), now: now) == "now")   // a clock a little ahead never shows a negative age
    #expect(shortAgo(nil) == "")
}

@Test func everyBuiltinThemeIsCompleteAndUnique() {
    let themes = Theme.popular
    #expect(Set(themes.map(\.id)).count == themes.count)
    for t in themes {
        guard let term = t.terminal, let palette = term.palette else { Issue.record("\(t.id): no terminal colors"); continue }
        #expect(palette.count == 16, "\(t.id): the terminal needs all 16 ANSI colors")
        #expect(["dark", "light"].contains(t.appearance), "\(t.id)")
        let colors = [term.background, term.foreground, term.cursor, term.selection].compactMap { $0 } + palette
        #expect(colors.allSatisfy { $0.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil }, "\(t.id): a color isn't #rrggbb")
    }
}

/// Restart from the sidebar: the new agent takes its old tab in its own workspace, which isn't the one on screen.
@MainActor @Test func aRestartedAgentKeepsItsTabInItsOwnWorkspace() {
    let app = AppModel(builtins: Builtins.all), host = EditorHost(app: app)
    var l = WorkspaceLayout()
    let old = l.add("session:old"); l.add("file:///x"); l.save("other", to: app.uiState)
    host.replaceInBackground("session:old", with: "session:new", workspace: "other")
    let after = WorkspaceLayout.load("other", from: app.uiState)
    #expect(after.tab(uri: "session:new")?.id == old.id && after.tab(uri: "session:old") == nil)
    #expect(after.allTabs.count == 2)
}

/// The shell follows what a tab shows through observed state, not a callback the tab calls: an untitled file that
/// gets text shows its dot.
@MainActor @Test func aTabsLookIsObserved() async throws {
    let tab = UntitledTab(uri: "untitled:1", app: AppModel(builtins: Builtins.all))
    var looks: [TabLook] = []
    track(owner: tab, now: false) { TabLook(tab) } changed: { looks.append($0) }
    tab.editor.setText("x"); tab.editor.onChange?("x")   // as typing does
    for _ in 0..<50 where looks.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(looks.map(\.isEdited) == [true])
}

/// Past the newest four, editor areas go; one with unsaved files stays listed, and goes on a later switch once saved.
@MainActor @Test func anAreaKeptForUnsavedFilesGoesOnceSaved() {
    var unsaved: Set<String> = ["e"]
    var (recent, gone) = EditorHost.evicting(["a", "b", "c", "d", "e", "f"], keep: 4) { unsaved.contains($0) }
    #expect(recent == ["a", "b", "c", "d", "e"] && gone == ["f"])
    unsaved = []
    (recent, gone) = EditorHost.evicting(["g"] + recent, keep: 4) { unsaved.contains($0) }
    #expect(recent == ["g", "a", "b", "c"] && gone == ["d", "e"])
}
