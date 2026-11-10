import AppKit
import Core
import Foundation
import TestSupport
import Testing
import WorkbenchKit

@testable import BuiltinActivity
@testable import BuiltinAgents
@testable import BuiltinBrowser
@testable import EditorKit
@testable import BuiltinFiles
@testable import BuiltinGit
@testable import BuiltinIssues
@testable import KelpApp
@testable import KelpKit

/// A file tab as an agent and the user share it: the agent's change shows when nothing is edited here, ⌘S writes the
/// user's edit, and never over a change the agent made meanwhile.
extension AppOfItsOwn {
    private func file(_ text: String) throws -> String {
        let dir = testHome + "/files-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = dir + "/notes.txt"
        try text.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }
    /// A tab on `p` once the daemon has read it (each test here has a daemon of its own: `AppRig`).
    private func opened(_ p: String, in rig: AppRig) async -> FileTab {
        let tab = FileTab(uri: TabURI.file(p), app: rig.app)
        await tab.loading?.value
        return tab
    }

    /// The close sheet says Save writes a deleted file at its old place again, and it does: it used to leave the tab open with
    /// no word. A plain save still doesn't write over what it hasn't seen.
    @Test func saveInTheCloseSheetPutsADeletedFileBack() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let p = try file("one\n")
        let tab = await opened(p, in: rig)
        tab.editor?.setText("mine\n")
        tab.editor?.onChange?("mine\n")
        try FileManager.default.removeItem(atPath: p)
        #expect(await !tab.writeAndClose())
        #expect(await tab.writeAndClose(answering: .missing))
        #expect(try String(contentsOfFile: p, encoding: .utf8) == "mine\n")
    }

    /// A crash leaves what was typed: the tab that opens next takes it back, as unsaved. A save takes it away for good.
    @Test func unsavedTextComesBackAfterACrash() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let p = try file("one\n")
        let tab = await opened(p, in: rig), kept = UnsavedBackup(app: rig.app, uri: tab.uri)
        tab.editor?.setText("mine\n")
        tab.editor?.onChange?("mine\n")
        #expect(try await waitFor(5) { kept.text != nil })
        let next = await opened(p, in: rig)
        #expect(next.editor?.text == "mine\n")
        #expect(try await waitFor(5) { next.isEdited })
        #expect(next.isEdited)
        #expect(await next.save())
        #expect(try await waitFor(5) { kept.text == nil })
        #expect(kept.text == nil)
    }

    /// An untitled tab was never on disk, so a crash would take all of it. Don't Save takes the kept text too.
    @Test func anUntitledTabComesBackUntilDontSave() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let tab = UntitledTab(uri: "untitled:1", app: rig.app), kept = UnsavedBackup(app: rig.app, uri: "untitled:1")
        tab.editor.setText("draft")
        tab.editor.onChange?("draft")
        #expect(try await waitFor(5) { kept.text != nil })
        let next = UntitledTab(uri: "untitled:1", app: rig.app)
        #expect(next.editor.text == "draft" && next.isEdited)
        next.discard()
        #expect(try await waitFor(5) { kept.text == nil })
        #expect(kept.text == nil)
    }

    /// One the saved layout never had still gets its tab; one whose workspace is gone goes.
    @Test func whatACrashLeftGetsATab() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let host = EditorHost(app: rig.app), workspace = rig.workspace.id
        rig.app.uiState["backup.\(workspace).untitled:7"] = .array(["untitled:7", .string(workspace), "x"])
        rig.app.uiState["backup.gone.untitled:8"] = .array(["untitled:8", "gone", "y"])
        // The workspaces didn't load (the daemon was slow): nothing is known gone, so nothing goes.
        rig.app.worktrees = []
        let client = rig.app.client
        rig.app.daemon.use(nil)
        await UnsavedBackups.reopen(rig.app, in: host)
        #expect(
            rig.app.uiState["backup.gone.untitled:8"] != nil && rig.app.uiState["backup.\(workspace).untitled:7"] != nil
        )
        rig.app.daemon.use(client)
        rig.app.worktrees = [rig.workspace]
        await UnsavedBackups.reopen(rig.app, in: host)
        #expect(rig.app.workbench.layouts[workspace].tab(uri: "untitled:7") != nil)
        #expect(rig.app.uiState["backup.gone.untitled:8"] == nil)
    }

    /// A tab dropped without its question (its workspace went and the save failed) keeps what was typed even before the
    /// pause in typing; a workspace gone hands a file's text to the workspace that holds the file, instead of dropping it.
    @Test func aDroppedTabsTextIsKeptForAWorkspaceHoldingIt() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let p = try file("one\n")
        var tab: FileTab? = await opened(p, in: rig)
        let kept = UnsavedBackup(app: rig.app, uri: TabURI.file(p))
        tab?.editor?.setText("mine\n")
        tab?.editor?.onChange?("mine\n")
        tab = nil
        #expect(try await waitFor(5) { kept.text != nil })
        #expect(kept.text == "mine\n")
        let inRepo = rig.workspace.path + "/kept.txt", uri = TabURI.file(inRepo)
        rig.app.uiState["backup.gone.\(uri)"] = .array([.string(uri), "gone", "typed"])
        await UnsavedBackups.reopen(rig.app, in: EditorHost(app: rig.app))
        #expect(rig.app.uiState["backup.gone.\(uri)"] == nil)
        #expect(rig.app.uiState.strings("backup.\(rig.workspace.id).\(uri)") == [uri, rig.workspace.id, "typed"])
        #expect(rig.app.workbench.layouts[rig.workspace.id].tab(uri: uri) != nil)
    }

    @Test func anAgentsChangeShowsWhenNothingIsEditedHere() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let p = try file("one\n")
        let tab = await opened(p, in: rig)
        #expect(tab.editor?.text == "one\n")
        try "two\n".write(toFile: p, atomically: true, encoding: .utf8)   // the agent
        #expect(try await waitFor(5) { !(tab.editor?.text != "two\n") })
        #expect(tab.editor?.text == "two\n")
    }

    @Test func saveWritesTheEditButNeverOverAnAgentsChange() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let p = try file("one\n")
        let tab = await opened(p, in: rig)
        tab.editor?.setText("mine\n")
        #expect(await tab.save())
        #expect(try String(contentsOfFile: p, encoding: .utf8) == "mine\n")
        tab.editor?.setText("mine again\n")
        try "theirs\n".write(toFile: p, atomically: true, encoding: .utf8)   // the agent, before ⌘S
        #expect(await !tab.save())   // asks (here: no window, so it just doesn't write)
        #expect(try String(contentsOfFile: p, encoding: .utf8) == "theirs\n")
    }

    /// Saving from the quit or close sheet (as Save All does) tidies like ⌘S: only ⌘S trimmed and ended the file.
    @Test func everySaveTheUserAsksForTidies() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        rig.app.settings.set(SettingKeys.trimTrailingWhitespace, true)
        rig.app.settings.set(SettingKeys.insertFinalNewline, true)
        let p = try file("one\n")
        let tab = await opened(p, in: rig)
        tab.editor?.setText("mine  ")
        tab.editor?.onChange?("mine  ")
        #expect(await UnsavedChanges.settle([tab], .alertFirstButtonReturn))
        #expect(try String(contentsOfFile: p, encoding: .utf8) == "mine\n")
    }

    /// The agent's version read while a save is on its way (its text is made off the main thread: a while for a big file,
    /// or on a busy machine) isn't the one the save was checked against: the save still doesn't write over it. It did.
    @Test func anAgentsVersionReadDuringASaveIsNotWrittenOver() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let p = try file("one\n")
        let tab = await opened(p, in: rig)
        #expect(try await waitFor(5) { rig.app.latest(FileEvent.self, p) != nil })   // the watch's first version
        tab.editor?.setText(String(repeating: "mine\n", count: 2_000_000))
        try "theirs\n".write(toFile: p, atomically: true, encoding: .utf8)   // the agent, as ⌘S checks
        let saved = Task { await tab.save() }
        rig.app.land(FileEvent(path: p, stamp: "theirs"))   // its version pushed at once: the tab reads it meanwhile
        #expect(await !saved.value)
        #expect(try String(contentsOfFile: p, encoding: .utf8) == "theirs\n")
    }

    /// Closing checks the version first and writes after a wait of its own (the save before it, the sheet): an agent's
    /// version read in between isn't the one it writes over.
    @Test func closingWritesOnlyOverTheVersionItChecked() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let p = try file("one\n")
        let tab = await opened(p, in: rig)
        #expect(try await waitFor(5) { rig.app.latest(FileEvent.self, p) != nil && tab.known != nil })
        let checked = tab.known?.stamp
        tab.editor?.setText("mine\n")
        tab.editor?.onChange?("mine\n")
        try "theirs\n".write(toFile: p, atomically: true, encoding: .utf8)
        #expect(try await waitFor(5) { tab.known?.stamp != checked })   // the agent's version read meanwhile
        #expect(await !tab.writeAndClose(over: checked))
        #expect(try String(contentsOfFile: p, encoding: .utf8) == "theirs\n")
    }

    /// An agent's change to a file edited here, once its version is pushed: the edit stays, and ⌘S asks instead of
    /// writing over it (here, with no window to ask in, it just doesn't write).
    @Test func anAgentsChangeToAnEditedFileKeepsTheEditAndAsks() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let p = try file("one\n")
        let tab = await opened(p, in: rig)
        tab.editor?.setText("mine\n")
        tab.editor?.onChange?("mine\n")
        let was = rig.app.latest(FileEvent.self, p)?.stamp
        try "theirs\n".write(toFile: p, atomically: true, encoding: .utf8)
        #expect(try await waitFor(5) { rig.app.latest(FileEvent.self, p)?.stamp != was })
        #expect(try await waitFor(5) { tab.known?.text == "theirs\n" })   // its text read, and judged in that turn
        #expect(tab.editor?.text == "mine\n" && tab.isEdited)
        #expect(!tab.gone)   // failed once on CI by saving over the file: this and `now` say which way it got there
        #expect(await !tab.save())
        let now = try String(contentsOfFile: p, encoding: .utf8)
        #expect(now == "theirs\n")
    }

    /// A file only touched (a new modification time, the same text) while edited here asks nothing: ⌘S writes the edit,
    /// whether its new version was pushed before the save or the daemon finds it at the save.
    @Test func aTouchedFileIsSavedWithoutAsking() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let p = try file("one\n")
        let tab = await opened(p, in: rig)
        func touch(_ ahead: Int) throws {
            var times = [
                timespec(tv_sec: 0, tv_nsec: Int(UTIME_NOW)),
                timespec(tv_sec: Int(Date().timeIntervalSince1970) + ahead, tv_nsec: 0)
            ]
            #expect(utimensat(AT_FDCWD, p, &times, 0) == 0)
        }
        tab.editor?.setText("mine\n")
        tab.editor?.onChange?("mine\n")
        let was = rig.app.latest(FileEvent.self, p)?.stamp
        try touch(5)
        #expect(try await waitFor(5) { rig.app.latest(FileEvent.self, p)?.stamp != was })
        #expect(await tab.save())
        #expect(try String(contentsOfFile: p, encoding: .utf8) == "mine\n")
        tab.editor?.setText("mine again\n")
        tab.editor?.onChange?("mine again\n")
        try touch(10)   // and saved before the daemon says so
        #expect(await tab.save())
        #expect(try String(contentsOfFile: p, encoding: .utf8) == "mine again\n")
    }

    /// Closing a workspace with an edited file: Cancel keeps it, Save writes it, Don't Save leaves nothing edited (so the
    /// workspace going away doesn't ask again); without Cancel the second button is Don't Save. Then what's left to wait
    /// for (a remote file's save) is nothing.
    @Test func closingAWorkspaceAsksAboutItsUnsavedFiles() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let p = try file("one\n")
        let tab = await opened(p, in: rig), untitled = UntitledTab(uri: "untitled:1", app: rig.app)
        func type(_ t: String) {
            tab.editor?.setText(t)
            tab.editor?.onChange?(t)
        }   // as typing does
        type("mine\n")
        #expect(await !UnsavedChanges.settle([tab], .alertSecondButtonReturn))   // Cancel
        #expect(tab.isEdited)
        #expect(await UnsavedChanges.settle([tab], .alertFirstButtonReturn))   // Save
        #expect(try String(contentsOfFile: p, encoding: .utf8) == "mine\n")
        type("mine again\n")
        #expect(tab.isEdited)
        #expect(await UnsavedChanges.settle([tab], .alertThirdButtonReturn))   // Don't Save
        #expect(!tab.isEdited)
        #expect(try String(contentsOfFile: p, encoding: .utf8) == "mine\n")
        untitled.editor.setText("draft")
        #expect(await UnsavedChanges.settle([untitled], .alertSecondButtonReturn, canCancel: false))   // Don't Save, no Cancel
        #expect(!untitled.isEdited)
        #expect(await UnsavedChanges.written([tab, untitled]))
    }

    /// The shell reaches a file tab only as `TabContent`: what it asks must be the tab's own answer, not the protocol's
    /// "not this one" default (a signature that drifts would fall back to it silently).
    @Test func theShellSeesAFileTabThroughTabContent() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let p = try file("a\nb\nc\nd\n")
        let file = await opened(p, in: rig)
        let tab: TabContent = file
        #expect(tab.fileURL == URL(fileURLWithPath: p))
        #expect(tab.badge == nil && tab.terminalGrid == nil)
        tab.goTo(line: 3)
        #expect(file.editor?.cursor?.line == 3)
        #expect(await tab.close())   // nothing edited: closes without asking
    }

    /// A keystroke at the end of a big file doesn't compare all of it with the saved text on the main thread (that took
    /// 110 ms for 3 MB, each one); a letter typed over and back still clears the dot, compared off it.
    @Test func typingInABigFileDoesntCompareItAll() async throws {
        let line = "let label = \"größe\" // a line of code\n"
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let p = try file(String(repeating: line, count: 3_000_000 / line.utf8.count))
        let tab = await opened(p, in: rig)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.contentView = tab.view
        let tv = try #require(tab.editor?.textView)
        let end = tv.length - 10
        let t0 = Date()
        for _ in 0..<5 { tv.replace([NSRange(location: end, length: 0)], with: ["x"]) }
        #expect(Date().timeIntervalSince(t0) < 0.15)
        #expect(tab.isEdited)
        #expect(await tab.save())
        #expect(!tab.isEdited)
        let was = (tv.string as NSString).substring(with: NSRange(location: end, length: 1))
        tv.replace([NSRange(location: end, length: 1)], with: ["y"])   // the saved length, other text
        #expect(tab.isEdited)
        tv.replace([NSRange(location: end, length: 1)], with: [was])   // the saved text again
        #expect(try await waitFor(5) { !(tab.isEdited) })
        #expect(!tab.isEdited)
    }

    /// A 60 MB log or a pipe isn't read whole on the main thread: the tab says why instead (a pipe used to block forever,
    /// /dev/zero to eat memory). A terminal path that's a pipe isn't a file to preview either.
    @Test func hugeFilesAndPipesAreNotReadIntoTheEditor() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let p = try file("")
        #expect(truncate(p, 60 << 20) == 0)   // sparse: no 60 MB written
        #expect(await opened(p, in: rig).editor == nil)
        let fifo = (p as NSString).deletingLastPathComponent + "/out.log"
        #expect(mkfifo(fifo, 0o600) == 0)
        #expect(await opened(fifo, in: rig).editor == nil)
        #expect(TerminalPaths.resolve("out.log", cwd: (fifo as NSString).deletingLastPathComponent) == nil)
        #expect(TerminalPaths.resolve("notes.txt", cwd: (fifo as NSString).deletingLastPathComponent) != nil)
    }

    /// A file event reads the file again only when its stamp (size, modification time, inode) changed: every event of a
    /// log a dev server appends to used to read all of it on the main thread.
    @Test func aFileEventWithTheSameStampReadsNothing() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let p = try file("aaaa\n")
        let tab = await opened(p, in: rig)
        #expect(try await waitFor(5) { tab.known != nil && !tab.reading })
        let known = try #require(tab.known?.stamp)
        // Its own version pushed again (a touch the daemon saw, an event sent twice): judged at once, not read. Landed
        // by hand: a file changed on disk and put back to its stamp is seen half way by the watch, which reads it.
        rig.app.land(FileEvent(path: p, stamp: known))
        tab.diskChanged()
        #expect(!tab.reading)
        try "cccc\n".write(toFile: p, atomically: true, encoding: .utf8)   // a real change still shows
        #expect(try await waitFor(5) { tab.editor?.text == "cccc\n" })
    }

    /// A preview written over (a new render of a video, an image) shows the new file: it used to keep the old one until
    /// the tab was opened again.
    @Test func aPreviewFollowsItsFile() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let p = try file("") + ".png"
        func png(_ side: Int) throws {
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            try #require(rep?.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: p))
        }
        try png(10)
        let tab = FileTab(uri: TabURI.file(p), app: rig.app)
        func side() -> CGFloat? { (tab.view.subviews.first as? ImagePreview)?.image?.size.width }
        #expect(side() == 10)
        #expect(try await waitFor(5) { rig.app.latest(FileEvent.self, p)?.stamp != nil })
        try png(20)
        #expect(try await waitFor(5) { side() == 20 })
    }
}

/// A picture bigger than the window is shown smaller: it used to grow the window to its own size (#39).
@MainActor @Test func aBigImageDoesntGrowTheWindow() {
    let image = NSImage(size: NSSize(width: 6000, height: 4000))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .resizable], backing: .buffered,
        defer: true)
    let box = NSView()
    window.contentView = box
    box.pin(ImagePreview(image: image, url: URL(fileURLWithPath: "/tmp/big.png")))
    window.layoutIfNeeded()
    #expect(window.contentLayoutRect.size == NSSize(width: 800, height: 600))
}

@MainActor @Test func aBreadcrumbShowsWhatsBesideIt() {
    #expect(Breadcrumbs.parts("/p/Sources/a.swift", root: "/p") == ["Sources", "a.swift"])
    #expect(Breadcrumbs.parts("/other/a.swift", root: "/p") == ["a.swift"])
    let paths = ["README.md", "Sources/b/x.swift", "Sources/b/y.swift", "Sources/a.swift", "Tests/t.swift"]
    #expect(Breadcrumbs.children(of: "", in: paths).map(\.name) == ["Sources", "Tests", "README.md"])
    #expect(Breadcrumbs.children(of: "Sources", in: paths).map(\.name) == ["b", "a.swift"])
    #expect(Breadcrumbs.children(of: "Sources", in: paths).map(\.isFolder) == [true, false])
}

/// What VS Code writes goes in as it is: a comment, a prefix list, a body of lines.
@Test func snippetsReadVSCodesFormat() throws {
    let text = """
        {
          // a comment
          "Test": { "prefix": ["test", "tt"], "body": ["func test$1() {", "\\t$0", "}"], "description": "A test" },
          "One": { "prefix": "one", "body": "$TM_FILENAME_BASE ${TM_FILENAME}" },
          "Broken": { "prefix": "x" },
        }
        """
    let all = try Snippets.read(text, path: "/p/a.swift")
    #expect(all.map(\.label) == ["one", "test", "tt"])
    #expect(all[0].insert == "a a.swift")
    #expect(
        all[1].insert.contains("\n") && all[1].snippet && all[1].documentation == "A test" && all[1].detail == "Test")
    #expect(throws: (any Error).self) { try Snippets.read("{", path: "/p/a.swift") }
}

/// A file reached through a symlink (/tmp is /private/tmp) is the file it leads to: opened again either way, it's the
/// tab already open. What isn't there stays as asked.
@Test @MainActor func aFileReachedThroughASymlinkIsTheSameFile() throws {
    let dir = "/tmp/kelp-real-\(UUID().uuidString.prefix(6))"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    FileManager.default.createFile(atPath: dir + "/a.txt", contents: Data())
    #expect(EditorArea.realPath(dir + "/a.txt") == "/private" + dir + "/a.txt")
    #expect(EditorArea.realPath("/nowhere/x.txt") == "/nowhere/x.txt")
    var layout = WorkspaceLayout()
    _ = layout.add(TabURI.file(dir + "/a.txt"), to: nil)
    #expect(layout.fileTab(sameFileAs: TabURI.file("/private" + dir + "/a.txt", line: 2)) == nil)   // by name alone: another
    #expect(
        layout.fileTab(sameFileAs: TabURI.file("/private" + dir + "/a.txt", line: 2), real: EditorArea.realPath) != nil)
}
