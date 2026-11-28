import AppKit
import Core
import DesignKit
import Foundation
import ImageIO
import JavaScriptCore
import TestSupport
import Testing

@testable import BuiltinFiles
@testable import EditorKit
@testable import KelpKit

extension OneAtATime {
    /// A grown page's Linked block names the line's place as text: a heading on the list (an agent may write one) is
    /// no markup in a page that can start agents.
    @Test func theLinkedBlockSaysWhereTheLineIsAsText() {
        _ = NSApplication.shared
        let app = AppModel()
        let root = "/tmp/kelp-linked-\(UUID().uuidString)"
        app.repos = [Repo(id: "r", name: "kelp", path: root)]
        let line = TaskLine(id: "g", text: "[Search](../search/doc.md)", line: 4, section: "<img src=x onerror=f()>")
        let list = TaskPage(
            path: root + "/.kelp/artifacts/tasks/doc.md", slug: "tasks", title: "Tasks <b>x</b>", tasks: [line],
            isList: true)
        app.latest(TasksEvent.self).byKey["r"] = TasksEvent(repo: "r", pages: [list])
        defer { app.latest(TasksEvent.self).byKey["r"] = nil }
        let url = URL(fileURLWithPath: root + "/.kelp/artifacts/search/doc.md")
        let tab = MarkdownTab(editor: CodeEditor(text: "# Search", url: url), url: url, app: app)
        let block = tab.linkedBlock()
        #expect(block.contains("&lt;img src=x onerror=f()&gt;") && !block.contains("<img"))
    }

    /// `kelp artifact check` on a motion page waits for the window's next drawing of it, as on a design.
    @Test func aMotionPageTakesAWaitingCheck() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-motion-check/.kelp/artifacts/launch/motion.html")
        let app = AppModel()
        let path = Paths.real(url.path) ?? url.path
        app.latest(ArtifactCheckEvent.self).byKey[path] = ArtifactCheckEvent(request: "r1", path: path)
        let tab = MarkdownTab(
            editor: CodeEditor(text: #"<body data-width="1920" data-height="1080"></body>"#, url: url), url: url,
            app: app)
        _ = tab.view
        #expect(tab.pendingCheck == "r1")
    }
}

extension OneAtATime {
    /// A dashboard's View menu has the languages a design has, but no themes: it follows the window's look.
    /// The zoom capsule lies over the sheet Mark and Edit draw on: a click on − + Fit reaches it, not a new mark.
    @Test func theZoomCapsuleIsOverTheMarkingSheet() throws {
        func layer(_ rule: String, in css: String) throws -> Int {
            let from = try #require(css.range(of: rule + " {"))
            let z = try #require(css[from.upperBound...].firstMatch(of: /z-index: (\d+)/))
            return try #require(Int(z.1))
        }
        #expect(try layer(".kelp-float", in: CanvasChrome.style) > layer(".kelp-sheet", in: CanvasEdit.style))
    }

    @Test func aDashboardsViewMenuHasNoThemes() {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-dash-view/.kelp/artifacts/numbers/canvas.json")
        let tab = MarkdownTab(editor: CodeEditor(text: #"{"boards": []}"#, url: url), url: url, app: AppModel())
        let titles = { tab.viewMenu().items.map(\.title) }
        #expect(titles().contains("Light"))
        tab.isDashboard = true
        #expect(titles().contains("Longer Text (+40%)") && !titles().contains("Light"))
    }
}

extension OneAtATime {
    /// A dashboard with sources offers how often it updates while open, and keeps the choice; a dashboard without
    /// sources (its agent updates it) and a design offer nothing.
    @Test func aDashboardWithSourcesChoosesHowOftenItUpdates() {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-dash-every/.kelp/artifacts/numbers/canvas.json")
        let json = #"{"boards": [], "sources": {"issues": {"run": "gh issue list --json number", "map": "length"}}}"#
        let tab = MarkdownTab(editor: CodeEditor(text: json, url: url), url: url, app: AppModel())
        #expect(tab.updateMenu() == nil, "a design")
        tab.isDashboard = true
        let menu = tab.updateMenu()
        #expect(menu?.items.map(\.title) == ["When Opened", "Every 15 Minutes", "Every Hour"])
        #expect(menu?.items.first?.state == .on)
        tab.updateEvery = 60
        #expect(tab.updateMenu()?.items.last?.state == .on)
        tab.updateEvery = nil
        let bare = MarkdownTab(editor: CodeEditor(text: #"{"boards": []}"#, url: url), url: url, app: AppModel())
        bare.isDashboard = true
        #expect(bare.updateMenu() == nil)
    }
}

extension OneAtATime {
    /// A CSV shown as a table: a cell changed changes the file's text, a row added and deleted too; a column's head
    /// sorts what's shown, numbers as numbers, and leaves the file as it is.
    @Test func aCSVIsChangedAsATable() throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-csv-grid/\(UUID().uuidString).csv")   // no widths or order kept
        let editor = CodeEditor(text: "name,sold\nB,10\nA,9\n", url: url)
        let csv = CSVGrid(editor: editor, path: url.path), grid = csv.grid, table = grid.table
        #expect(table.numberOfRows == 2 && table.tableColumns.map(\.title) == ["name", "sold"])
        let sold = grid.tableView(table, viewFor: table.tableColumns[1], row: 0) as? NSTextField
        #expect(sold?.stringValue == "10" && sold?.alignment == .right, "a column of numbers lines up at the right")
        grid.set("11", row: 1, column: 1)
        grid.onEdit()
        #expect(editor.text == "name,sold\nB,11\nA,9\n")
        table.sortDescriptors = [NSSortDescriptor(key: "1", ascending: true)]
        #expect((grid.tableView(table, viewFor: table.tableColumns[0], row: 0) as? NSTextField)?.stringValue == "A")
        #expect(editor.text == "name,sold\nB,11\nA,9\n", "sorting shows; the file stays")
        editor.apply(text: "name,sold\nC,1\n", selection: NSRange(location: 0, length: 0))
        csv.changed(editor.text)
        #expect(table.numberOfRows == 1)
        csv.modes.selectedSegment = 1
        csv.modeChosen()
        #expect(csv.view.subviews.first === editor.view, "Text shows the file's text")
    }
}

extension OneAtATime {
    /// A page whose process ended (out of memory, a crash) is drawn again rather than left blank.
    @Test func aPageWhoseProcessEndedIsDrawnAgain() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-page-ended/notes.md")
        let tab = MarkdownTab(editor: CodeEditor(text: "# Notes", url: url), url: url, app: AppModel())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentViewController = tab
        #expect(try await waitFor(10) { MarkdownTab.loaded.object(forKey: tab) != nil && !tab.web.isLoading })
        MarkdownTab.loaded.removeObject(forKey: tab)   // loaded, it would be drawn again in place, not whole
        tab.links.webViewWebContentProcessDidTerminate(tab.web)
        #expect(try await waitFor(10) { MarkdownTab.loaded.object(forKey: tab) != nil })
    }
}

extension OneAtATime {
    /// Edit › Find with the page focused shows the find card over the page, not a beep.
    @Test func findOnThePageShowsItsFindCard() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-page-find/notes.md")
        let tab = MarkdownTab(editor: CodeEditor(text: "# Notes\n\nfind me", url: url), url: url, app: AppModel())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentViewController = tab
        #expect(try await waitFor(10) { MarkdownTab.loaded.object(forKey: tab) != nil })
        window.makeFirstResponder(tab.web)
        let find = NSMenuItem(
            title: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        #expect(
            NSApp.sendAction(find.action!, to: nil, from: find)
                || window.firstResponder?.tryToPerform(find.action!, with: find) == true)
        func cards(_ v: NSView) -> Int { (v is FindCard ? 1 : 0) + v.subviews.map(cards).reduce(0, +) }
        #expect(cards(tab.view) == 1)
    }
}

extension OneAtATime {
    /// An agent's page opens at the zoom it was left at; the place is kept by the page, not by the tab.
    @Test func aPageOpensAtTheZoomItWasLeftAt() {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-place/.kelp/artifacts/home/canvas.json")
        let app = AppModel()
        app.uiState["artifacts.place:.kelp/artifacts/home/canvas.json"] = .object(["zoom": .double(0.5), "y": .int(120)]
        )
        let tab = MarkdownTab(editor: CodeEditor(text: #"{"boards": []}"#, url: url), url: url, app: app)
        #expect(tab.keptPlace.zoom == 0.5 && tab.keptPlace.y == 120)
        tab.restorePlace()
        #expect(tab.canvasZoom == 0.5)
        let other = URL(fileURLWithPath: "/tmp/kelp-place/notes.md")
        #expect(MarkdownTab(editor: CodeEditor(text: "", url: other), url: other, app: app).keptPlace.zoom == nil)
    }
}

extension OneAtATime {
    /// The check bar says what else the agent's turn changed, by the boards' names.
    @Test func theCheckBarSaysWhatElseTheTurnChanged() throws {
        _ = NSApplication.shared
        let bar = MarkReviewBar(act: { _ in })
        bar.show(
            count: 1, at: 0, before: (false, true), who: "Codex", said: ("bigger", "done"),
            elsewhere: ["boards/C.html", "boards/D-pricing.html"])
        func labels(_ v: NSView) -> [String] {
            ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(labels)
        }
        #expect(labels(bar.bar).contains { $0.hasSuffix("also changed C, D-pricing") })
        bar.show(count: 2, at: 1, before: (false, true), who: nil, said: ("", ""), cost: "$0.08")
        #expect(labels(bar.bar).contains("2 of 2 · $0.08"))
    }
}

/// A quote in a doc is found by its first words: its line, and the heading it sits under.
@Test(
    arguments: [
        ("# Plan\n\n## Pricing\n\nWe charge   per\nseat.", "We charge per seat", 5, "Pricing" as String?),
        ("Intro words here.", "Intro words", 1, nil)
    ] as [(String, String, Int, String?)])
func aQuoteIsFoundByItsWords(markdown: String, quote: String, line: Int, heading: String?) throws {
    let place = try #require(MarkdownTab.place(of: quote, in: markdown))
    #expect(place.line == line && place.heading == heading)
}

extension OneAtATime {
    /// The column's script reads as JavaScript: one that doesn't leaves the column empty, with no error shown.
    @Test func theMarkColumnsScriptReads() throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-column/.kelp/artifacts/x/canvas.json")
        let tab = MarkdownTab(editor: CodeEditor(text: #"{"boards": []}"#, url: url), url: url, app: AppModel())
        _ = tab
        let source = MarkColumn.source(marks: ArtifactMarks(), labels: [:])
        let context = try #require(JSContext())
        let quoted = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        context.evaluateScript("new Function(\(quoted))")
        #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
        let multi = String(decoding: try JSONEncoder().encode(CanvasMulti.source(labels: [:])), as: UTF8.self)
        context.evaluateScript("new Function(\(multi))")
        #expect(context.exception == nil, "several at once: \(context.exception?.toString() ?? "")")
    }
}

extension OneAtATime {
    /// Undo the agent's last turn brings back the version before it: one made by hand counts as before, a restore
    /// isn't a turn.
    @Test func undoingTheLastTurnBringsBackTheVersionBeforeIt() {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-undo-turn/.kelp/artifacts/home/canvas.json")
        let app = AppModel()
        let tab = MarkdownTab(editor: CodeEditor(text: #"{"boards": []}"#, url: url), url: url, app: app)
        let bar = ArtifactBar(app: app, path: url.path, markdown: tab)
        var item = ArtifactItem(slug: "home", type: "design", title: "Home", created: 0, target: url.path)
        item.versions = [
            .init(n: 1, at: 0, label: "make it"), .init(n: 2, at: 1, label: "title", byUser: true),
            .init(n: 3, at: 2, label: "bigger"), .init(n: 4, at: 3, label: "Restored", restored: 1)
        ]
        bar.item = item
        #expect(bar.beforeLastTurn?.n == 2)
        item.versions = [.init(n: 1, at: 0, label: "make it")]
        bar.item = item
        #expect(bar.beforeLastTurn == nil, "the first turn has nothing before it")
    }
}

/// A colour in the menu says, only when it is too faint for text, how it reads against the element's ground.
@MainActor @Test func aColourSaysHowItReads() throws {
    let black = try #require(NSColor(css: "#000")), white = try #require(NSColor(css: "#ffffff"))
    #expect(abs(MarkdownTab.contrast(black, white) - 21) < 0.01 && MarkdownTab.contrast(white, white) == 1)
    #expect(
        MarkdownTab.faint(21) == nil && MarkdownTab.faint(4.5) == nil
            && MarkdownTab.faint(3)?.hasPrefix("3.0:1: ") == true)
    #expect(try #require(NSColor(css: "#0a84ff")).hexString == "#0a84ff")
    let warned = MarkdownTab.warned("Muted", column: 40)
    let sign = warned.attribute(.attachment, at: warned.length - 1, effectiveRange: nil) as? NSTextAttachment
    #expect(warned.string.hasPrefix("Muted\t") && sign?.image != nil, "the sign after the name, at its column")
}

extension OneAtATime {
    /// ⌘C then ⌘V on a chosen element puts a copy after the element chosen then, its data-ids numbered anew.
    @Test func anElementCopiedIsPastedAfterTheChosenOne() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-paste/.kelp/artifacts/launch/motion.html")
        let page =
            #"<body data-width="1920" data-height="1080"><h1 data-id="title">Hi</h1><p data-id="sub">Go</p></body>"#
        let editor = CodeEditor(text: page, url: url)
        let tab = MarkdownTab(editor: editor, url: url, app: AppModel())
        NSPasteboard.general.clearContents()
        _ = tab.canvasMessage("copyElement", ["board": "motion.html", "id": "title"])
        #expect(try await waitFor(5) { NSPasteboard.general.string(forType: MarkdownTab.elementType) != nil })
        _ = tab.canvasMessage("pasteElement", ["board": "motion.html", "id": "sub"])
        #expect(try await waitFor(5) { editor.text.contains(#"<p data-id="sub">Go</p><h1 data-id="title-2">Hi</h1>"#) })
    }
}

extension OneAtATime {
    /// Several chosen elements taken out at once are one hand edit, one ⌘Z; the edit column's words are all there.
    @Test func severalElementsTakenOutAreOneStep() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-many/.kelp/artifacts/launch/motion.html")
        let page =
            #"<body data-width="1920" data-height="1080"><i data-id="a">1</i><i data-id="b">2</i><i data-id="c">3</i></body>"#
        let editor = CodeEditor(text: page, url: url)
        let tab = MarkdownTab(editor: editor, url: url, app: AppModel())
        #expect(tab.canvasEditMoreLabels["multiChosen"] != nil)
        _ = tab.canvasMessage("removeMany", ["board": "motion.html", "ids": ["a", "c"]])
        #expect(
            try await waitFor(5) {
                editor.text.contains(#"<i data-id="b">2</i></body>"#) && !editor.text.contains("data-id=\"a\"")
            })
        #expect(tab.handSteps.undo.count == 1)
    }
}

extension OneAtATime {
    /// Insert › Text puts a new text after the chosen element; a second one gets an id of its own.
    @Test func insertPutsANewElementAfterTheChosenOne() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-insert/.kelp/artifacts/launch/motion.html")
        let editor = CodeEditor(
            text: #"<body data-width="1920" data-height="1080"><h1 data-id="title">Hi</h1></body>"#, url: url)
        let tab = MarkdownTab(editor: editor, url: url, app: AppModel())
        let menu = tab.insertMenu("motion.html", after: "title")
        #expect(menu.items.map(\.title).count == 4)
        menu.performActionForItem(at: 0)
        #expect(
            try await waitFor(5) { editor.text.contains(#"<h1 data-id="title">Hi</h1><p data-id="text">Text</p>"#) })
    }
}

extension OneAtATime {
    /// A layer locked and named from its row is written into the board's file.
    @Test func aLayerIsLockedAndNamedFromItsRow() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-layer-row/.kelp/artifacts/launch/motion.html")
        let editor = CodeEditor(
            text: #"<body data-width="1920" data-height="1080"><div data-id="bg">x</div></body>"#, url: url)
        let tab = MarkdownTab(editor: editor, url: url, app: AppModel())
        _ = tab.canvasMessage("attribute", ["board": "motion.html", "id": "bg", "name": "data-locked", "value": "true"])
        #expect(try await waitFor(5) { editor.text.contains(#"data-locked="true""#) })
        _ = tab.canvasMessage(
            "attribute", ["board": "motion.html", "id": "bg", "name": "data-title", "value": "Background"])
        #expect(try await waitFor(5) { editor.text.contains(#"data-title="Background""#) })
    }
}

extension OneAtATime {
    /// The page's messages about marks reach their handler: Point Again, Send To and Stop among them.
    @Test func marksMessagesReachTheirHandler() {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-route/.kelp/artifacts/home/canvas.json")
        let tab = MarkdownTab(editor: CodeEditor(text: #"{"boards": []}"#, url: url), url: url, app: AppModel())
        #expect(tab.canvasMessage("markTarget", ["id": 1, "mark": [:] as [String: Any]]))
        #expect(tab.canvasMessage("stopAgent", [:]))
    }
}

extension AppOfItsOwn {
    /// A page's tab closed while its bar still waits for kelpd to read a version: the late answer lands nowhere.
    @Test func aVersionReadThatEndsAfterItsTabClosedLandsNowhere() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let url = URL(fileURLWithPath: rig.workspace.path + "/.kelp/artifacts/home/page.md")
        var tab: MarkdownTab? = MarkdownTab(editor: CodeEditor(text: "# Home", url: url), url: url, app: rig.app)
        var bar: ArtifactBar? = ArtifactBar(app: rig.app, path: url.path, markdown: try #require(tab))
        weak let closed = tab, gone = bar
        bar?.followBaseline(versions: [.init(n: 1, at: 0, label: "a"), .init(n: 2, at: 1, label: "b")], live: false)
        (tab, bar) = (nil, nil)
        #expect(closed == nil)
        let page = ArtifactItem(slug: "home", type: "doc", title: "Home", created: 0, target: url.path)
        rig.app.land(ArtifactsEvent(worktree: rig.workspace.id, items: [page]))   // what the bar watches changes too
        try await waitFor { gone == nil }   // the read answered, and the bar let go
    }

    /// A board taken off the canvas keeps its file: duplicating the board again makes a file of its own beside it,
    /// never over the one left.
    @Test func aDuplicatedBoardNeverWritesOverAFileLeftOnDisk() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let folder = URL(fileURLWithPath: rig.workspace.path + "/.kelp/artifacts/home")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "<p>home</p>".write(to: folder.appendingPathComponent("home.html"), atomically: true, encoding: .utf8)
        let left = folder.appendingPathComponent("home-copy.html")
        try "<p>edited</p>".write(to: left, atomically: true, encoding: .utf8)
        let url = folder.appendingPathComponent("canvas.json")
        let canvas = #"{"boards": [{"file": "home.html", "title": "Home"}]}"#
        let tab = MarkdownTab(editor: CodeEditor(text: canvas, url: url), url: url, app: rig.app)
        await tab.duplicateBoard("home.html").value
        #expect(try String(contentsOf: left, encoding: .utf8) == "<p>edited</p>")
        let copy = try #require(ArtifactCanvas.read(tab.editor.text)?.boards.last?.file)
        #expect(copy != "home-copy.html")
        #expect(try String(contentsOf: folder.appendingPathComponent(copy), encoding: .utf8) == "<p>home</p>")
    }
}

extension OneAtATime {
    /// The versions column's foot is a panel bar that sizes itself: no second height pinned on it, which AppKit has to
    /// break at every text size.
    @Test func theVersionsColumnAsksForNoHeightItCantHave() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-versions-foot/.kelp/artifacts/home/page.md")
        let app = AppModel()
        let tab = MarkdownTab(editor: CodeEditor(text: "# Home", url: url), url: url, app: app)
        let bar = ArtifactBar(app: app, path: url.path, markdown: tab)   // the panel holds it unowned
        var panel: VersionsPanel? = VersionsPanel(bar: bar)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [], backing: .buffered,
            defer: true)
        window.contentView = panel
        weak let gone = panel
        window.layoutIfNeeded()
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        // Heights set as numbers, not the system's own content sizes (those may give way by design), measured as
        // constraints measure them: a separator's frame is wider than its line.
        let broken = all(try #require(panel)).flatMap(\.constraints).filter { c in
            guard type(of: c) == NSLayoutConstraint.self, c.isActive, c.priority == .required, c.relation == .equal,
                c.secondItem == nil, c.firstAttribute == .height, let view = c.firstItem as? NSView
            else { return false }
            return abs(view.alignmentRect(forFrame: view.frame).height - c.constant) > 0.5
        }
        #expect(broken.isEmpty, "heights AppKit had to break: \(broken)")
        // Its read of the kept names still runs and reads the bar: the bar stays until the panel is gone.
        (window.contentView, panel) = (nil, nil)
        try await waitFor { gone == nil }
        withExtendedLifetime(bar) {}
    }
}
