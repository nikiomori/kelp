import AppKit
import Core
import DesignKit
import Foundation
import TestSupport
import Testing
import WorkbenchKit

@testable import BuiltinActivity
@testable import BuiltinAgents
@testable import BuiltinBrowser
@testable import BuiltinFiles
@testable import BuiltinGit
@testable import BuiltinIssues
@testable import KelpApp
@testable import KelpKit

/// A project's icon is looked for off the main thread: its initial shows at once, the icon once it's found.
@MainActor @Test func aProjectsIconIsFoundOffTheMainThread() async throws {
    let dir = testHome + "/icon-\(UUID().uuidString.prefix(6))"
    try FileManager.default.createDirectory(atPath: dir + "/public", withIntermediateDirectories: true)
    let svg =
        #"<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><circle cx="16" cy="16" r="10" fill="red"/></svg>"#
    try svg.write(toFile: dir + "/public/favicon.svg", atomically: true, encoding: .utf8)
    let view = NSImageView(), app = AppModel(builtins: Builtins.all)
    ProjectIcon.show(dir, in: view, app: app)
    let initial = try #require(view.image)
    #expect(try await waitFor(5) { !(view.image === initial) })
    #expect(view.image !== initial && view.image?.size == NSSize(width: 32, height: 32))
    #expect(ProjectIcon.image(for: dir, app: app) === view.image)   // found once
}

/// Its window losing focus ends the rows' pointer events: a card left open would be laid out over and over, for hours.
@MainActor @Test func aHoverCardGoesWithItsWindowsFocus() async throws {
    let rig = try await AppRig()
    defer { rig.done() }
    let vc = NSViewController()
    vc.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    rig.show(vc, 200, 200)
    let card = HoverCard(app: rig.app)
    card.hover(.project(rig.project.id), rect: NSRect(x: 0, y: 0, width: 200, height: 24), in: vc.view)
    #expect(try await waitFor(5) { !(card.shownKind == nil) })
    #expect(card.shownKind != nil)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: NSWindow())   // another window's: not its
    await mainActorTurns()
    #expect(card.shownKind != nil)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: vc.view.window)
    #expect(try await waitFor(5) { !(card.shownKind != nil) })
    #expect(card.shownKind == nil)
}

/// A tab's look is compared with its last on every session's change: a new image each time never equals it.
@MainActor @Test func anAgentsIconIsTheSameImageUntilItsSourceChanges() {
    let app = AppModel(builtins: Builtins.all)
    let id = "some-agent-without-an-icon"
    let letter = app.catalog.icon(id)
    #expect(letter != nil && letter === app.catalog.icon(id))
    #expect(letter !== app.catalog.icon(id, size: 24))
    #expect(app.catalog.icon("shell") === app.catalog.icon(nil))
    for key in app.agentIcons.made.keys { app.agentIcons.made[key]?.source = NSImage() }   // not what agentIcons holds now
    #expect(app.catalog.icon(id) !== letter)
    let tile = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { r in
        NSColor.red.setFill()
        r.fill()
        return true
    }
    #expect(app.agentIcons.grey(tile) === app.agentIcons.grey(tile))
}

/// Off stays off: a tab's refresh must not start a fade on a glow nobody sees.
@MainActor @Test func aGlowAskedForWhatItAlreadyShowsDoesNothing() {
    let glow = EdgeGlow(radius: 4, spread: 2)
    glow.show(nil, breathing: false)
    #expect(glow.isHidden)
    glow.show(.systemOrange, breathing: false)
    #expect(!glow.isHidden)
    glow.alphaValue = 0.3
    glow.show(.systemOrange, breathing: false)
    #expect(glow.alphaValue == 0.3)
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

@MainActor @Test func everyBuiltinThemeIsCompleteAndUnique() {
    let themes = ThemeManager.builtin + Theme.looks + Theme.popular
    #expect(Set(themes.map(\.id)).count == themes.count)
    for t in themes {
        guard let term = t.terminal, let palette = term.palette else {
            Issue.record("\(t.id): no terminal colors")
            continue
        }
        #expect(palette.count == 16, "\(t.id): the terminal needs all 16 ANSI colors")
        #expect(["dark", "light"].contains(t.appearance), "\(t.id)")
        let colors = [term.background, term.foreground, term.cursor, term.selection].compactMap { $0 } + palette
        #expect(
            colors.allSatisfy { $0.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil },
            "\(t.id): a color isn't #rrggbb")
    }
}

/// A look is only as good as what can be read on it: what it names must exist, its text must stand out from its card.
@Test func everyLookNamesWhatExistsAndStaysReadable() {
    func luminance(_ hex: String) -> Double {
        guard let c = NSColor(hex: hex)?.usingColorSpace(.sRGB) else { return -1 }
        let f = { (v: CGFloat) in v <= 0.03928 ? Double(v) / 12.92 : pow((Double(v) + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(c.redComponent) + 0.7152 * f(c.greenComponent) + 0.0722 * f(c.blueComponent)
    }
    func contrast(_ a: String, _ b: String) -> Double {
        let l = [luminance(a), luminance(b)].sorted()
        return (l[1] + 0.05) / (l[0] + 0.05)
    }
    for t in Theme.looks {
        guard let term = t.terminal, let code = t.editor, let w = t.window else {
            Issue.record("\(t.id): a look sets all three")
            continue
        }
        #expect(contrast(term.foreground, term.background) >= 7, "\(t.id): text")
        // Ghostty holds colours against the background times its opacity: on a light see-through terminal they'd go black.
        if t.appearance == "light", let opacity = term.opacity {
            let held = (term.palette ?? []).filter {
                (opacity * luminance(term.background) + 0.05) / (luminance($0) + 0.05) < 2.9
            }
            #expect(held.isEmpty, "\(t.id): \(held) go black")
        }
        #expect(contrast(code.comment ?? "", term.background) >= 2.5, "\(t.id): comments")
        if let accent = w.accent { #expect(contrast(accent, w.surface ?? "") >= 3, "\(t.id): accent") }
        #expect(w.ambient.map { WindowLook.Ambient.Kind(rawValue: $0) != nil } ?? true, "\(t.id): ambient")
        #expect(w.font.map { ["mono", "serif", "rounded"].contains($0) } ?? true, "\(t.id): font")
        #expect(
            [w.surface, w.card, w.border, w.accent].compactMap { $0 }.allSatisfy {
                $0 == "material" || NSColor(hex: $0) != nil
            }, "\(t.id): a color")
    }
}

@MainActor @Test func aThemeBuildsItsWindow() throws {
    let nord = try #require(Theme.popular.first { $0.id == "nord" }), kelp = try #require(ThemeManager.builtin.first)
    #expect(ThemeManager.windowLook(nil, terminalOpacity: 1, forced: nil) == WindowLook())   // Ghostty's: the system's window
    #expect(ThemeManager.windowLook(nil, terminalOpacity: 0.6, forced: 0.6).card == .clear)
    #expect(ThemeManager.windowLook(kelp, terminalOpacity: 1, forced: nil) == WindowLook())
    let own = ThemeManager.windowLook(nord, terminalOpacity: 1, forced: nil)
    #expect(own.card == NSColor(hex: "#2e3440") && own.solid && !own.seeThrough)
    // Settings › Terminal opacity opens up any theme: the card goes clear, the desktop comes through the surface.
    let open = ThemeManager.windowLook(nord, terminalOpacity: 0.6, forced: 0.6)
    #expect(open.card == .clear && open.seeThrough && !open.solid && open.surface?.alphaComponent == 0.6)
    // A see-through look keeps its own surface when nothing forces it.
    let sea = try #require(Theme.looks.first { $0.id == "kelp.deep-sea" })
    let look = ThemeManager.windowLook(sea, terminalOpacity: 0.65, forced: nil)
    #expect(look.card == .clear && look.solid && look.ambient?.kind == .motes)
}

@Test func coloursTakeAlpha() throws {
    #expect(try #require(NSColor(hex: "#ffffff80")).alphaComponent == CGFloat(0x80) / 255)
    #expect(try #require(NSColor(hex: "#102030")).alphaComponent == 1)
    #expect(NSColor(hex: "#fff") == nil && NSColor(hex: "#ffffff8") == nil)
}

/// Restart from the sidebar: the new agent takes its old tab in its own workspace, which isn't the one on screen.
@MainActor @Test func aRestartedAgentKeepsItsTabInItsOwnWorkspace() {
    let app = AppModel(builtins: Builtins.all), host = EditorHost(app: app)
    var l = WorkspaceLayout()
    let old = l.add("session:old")
    l.add("file:///x")
    l.save("other", to: app.uiState)
    host.replaceInBackground("session:old", with: "session:new", workspace: "other")
    app.workbench.layouts.save()
    let after = WorkspaceLayout.load("other", from: app.uiState)
    #expect(after.tab(uri: "session:new")?.id == old.id && after.tab(uri: "session:old") == nil)
    #expect(after.allTabs.count == 2)
}

/// The shell follows what a tab shows through observed state, not a callback the tab calls: an untitled file that
/// gets text shows its dot.
@MainActor @Test func aTabsLookIsObserved() async throws {
    let tab = UntitledTab(uri: "untitled:1", app: AppModel(builtins: Builtins.all))
    var looks: [TabLook] = []
    track(owner: tab, now: false) {
        TabLook(tab)
    } changed: {
        looks.append($0)
    }
    tab.editor.setText("x")
    tab.editor.onChange?("x")   // as typing does
    #expect(try await waitFor(5) { !(looks.isEmpty) })
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

/// Agents Side by Side is in the title bar only with two agents or more that would tile: not a terminal, a run, an ended
/// or paused one, nor another workspace's.
@MainActor @Test func sideBySideCountsTheAgentsThatWouldTile() {
    _ = testHome
    let m = AppModel(builtins: Builtins.all)
    func s(_ w: String, _ agent: String, _ status: AgentStatus = .working) -> Session {
        Session(worktreeId: w, cwd: "/", command: agent, agent: agent, status: status, title: agent)
    }
    m.sessions = [
        s("w1", "claude"), s("w1", "shell"), s("w1", "custom"), s("w1", "codex", .exited), s("w1", "codex", .paused),
        s("w2", "codex")
    ]
    #expect(WindowBar.liveAgents(m, in: "w1") == 1)
    m.sessions.append(s("w1", "codex", .idle))
    #expect(WindowBar.liveAgents(m, in: "w1") == 2)
}

/// A form sheet's fields end where its buttons end, and its names stand in one column.
@MainActor @Test func aFormSheetsFieldsEndWhereItsButtonsEnd() {
    let field = NSTextField(), cancel = NSButton(title: "Cancel", target: nil, action: nil)
    let buttons = NSStackView(views: [NSView(), cancel])
    let grid = SheetForm.grid([("URL", field)])
    let stack = SheetForm.stack([grid, buttons], wide: [buttons], width: Metrics.sheetWidth)
    stack.frame = NSRect(x: 0, y: 0, width: Metrics.sheetWidth, height: 200)
    stack.layoutSubtreeIfNeeded()
    let fieldEnd = field.convert(field.bounds, to: stack).maxX,
        buttonsEnd = buttons.convert(buttons.bounds, to: stack).maxX
    #expect(fieldEnd == buttonsEnd && buttonsEnd == Metrics.sheetWidth - Metrics.sheetInset)
    #expect(grid.column(at: 0).width == Metrics.formLabel)
}
