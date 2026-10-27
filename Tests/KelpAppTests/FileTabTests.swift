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
    private func until(_ ok: () -> Bool) async throws {
        for _ in 0..<200 where !ok() { try await Task.sleep(for: .milliseconds(25)) }
    }

    @Test func anAgentsChangeShowsWhenNothingIsEditedHere() async throws {
        let rig = try await AppRig(files: [:]); defer { rig.done() }
        let p = try file("one\n")
        let tab = await opened(p, in: rig)
        #expect(tab.editor?.text == "one\n")
        try "two\n".write(toFile: p, atomically: true, encoding: .utf8)   // the agent
        for _ in 0..<100 where tab.editor?.text != "two\n" { try await Task.sleep(for: .milliseconds(50)) }
        #expect(tab.editor?.text == "two\n")
    }

    @Test func saveWritesTheEditButNeverOverAnAgentsChange() async throws {
        let rig = try await AppRig(files: [:]); defer { rig.done() }
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

    /// An agent's change to a file edited here, once its version is pushed: the edit stays, and ⌘S asks instead of
    /// writing over it (here, with no window to ask in, it just doesn't write).
    @Test func anAgentsChangeToAnEditedFileKeepsTheEditAndAsks() async throws {
        let rig = try await AppRig(files: [:]); defer { rig.done() }
        let p = try file("one\n")
        let tab = await opened(p, in: rig)
        tab.editor?.setText("mine\n"); tab.editor?.onChange?("mine\n")
        let was = rig.app.fileVersions[p]?.stamp
        try "theirs\n".write(toFile: p, atomically: true, encoding: .utf8)
        try await until { rig.app.fileVersions[p]?.stamp != was }
        try await Task.sleep(for: .milliseconds(200))   // its text read meanwhile
        #expect(tab.editor?.text == "mine\n" && tab.isEdited)
        #expect(await !tab.save())
        #expect(try String(contentsOfFile: p, encoding: .utf8) == "theirs\n")
    }

    /// A file only touched (a new modification time, the same text) while edited here asks nothing: ⌘S writes the edit,
    /// whether its new version was pushed before the save or the daemon finds it at the save.
    @Test func aTouchedFileIsSavedWithoutAsking() async throws {
        let rig = try await AppRig(files: [:]); defer { rig.done() }
        let p = try file("one\n")
        let tab = await opened(p, in: rig)
        func touch(_ ahead: Int) throws {
            var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_NOW)), timespec(tv_sec: Int(Date().timeIntervalSince1970) + ahead, tv_nsec: 0)]
            #expect(utimensat(AT_FDCWD, p, &times, 0) == 0)
        }
        tab.editor?.setText("mine\n"); tab.editor?.onChange?("mine\n")
        let was = rig.app.fileVersions[p]?.stamp
        try touch(5)
        try await until { rig.app.fileVersions[p]?.stamp != was }
        #expect(await tab.save())
        #expect(try String(contentsOfFile: p, encoding: .utf8) == "mine\n")
        tab.editor?.setText("mine again\n"); tab.editor?.onChange?("mine again\n")
        try touch(10)   // and saved before the daemon says so
        #expect(await tab.save())
        #expect(try String(contentsOfFile: p, encoding: .utf8) == "mine again\n")
    }

    /// Closing a workspace with an edited file: Cancel keeps it, Save writes it, Don't Save leaves nothing edited (so the
    /// workspace going away doesn't ask again); without Cancel the second button is Don't Save. Then what's left to wait
    /// for (a remote file's save) is nothing.
    @Test func closingAWorkspaceAsksAboutItsUnsavedFiles() async throws {
        let rig = try await AppRig(files: [:]); defer { rig.done() }
        let p = try file("one\n")
        let tab = await opened(p, in: rig), untitled = UntitledTab(uri: "untitled:1", app: rig.app)
        func type(_ t: String) { tab.editor?.setText(t); tab.editor?.onChange?(t) }   // as typing does
        type("mine\n")
        #expect(await !UnsavedChanges.settle([tab], .alertSecondButtonReturn))   // Cancel
        #expect(tab.isEdited)
        #expect(await UnsavedChanges.settle([tab], .alertFirstButtonReturn))     // Save
        #expect(try String(contentsOfFile: p, encoding: .utf8) == "mine\n")
        type("mine again\n")
        #expect(tab.isEdited)
        #expect(await UnsavedChanges.settle([tab], .alertThirdButtonReturn))     // Don't Save
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
        let rig = try await AppRig(files: [:]); defer { rig.done() }
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
        let rig = try await AppRig(files: [:]); defer { rig.done() }
        let p = try file(String(repeating: line, count: 3_000_000 / line.utf8.count))
        let tab = await opened(p, in: rig)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
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
        for _ in 0..<100 where tab.isEdited { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!tab.isEdited)
    }

    /// A 60 MB log or a pipe isn't read whole on the main thread: the tab says why instead (a pipe used to block forever,
    /// /dev/zero to eat memory). A terminal path that's a pipe isn't a file to preview either.
    @Test func hugeFilesAndPipesAreNotReadIntoTheEditor() async throws {
        let rig = try await AppRig(files: [:]); defer { rig.done() }
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
    /// log a dev server appends to used to read all of it on the main thread. Rewritten in place with the same size and
    /// its old modification time put back, the file looks untouched, so the tab keeps what it read.
    @Test func aFileEventWithTheSameStampReadsNothing() async throws {
        let rig = try await AppRig(files: [:]); defer { rig.done() }
        let p = try file("aaaa\n")
        let tab = await opened(p, in: rig)
        var st = stat()
        #expect(stat(p, &st) == 0)
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: p))
        try h.write(contentsOf: Data("bbbb\n".utf8)); try h.close()   // same inode, same size
        var times = [st.st_atimespec, st.st_mtimespec]
        #expect(utimensat(AT_FDCWD, p, &times, 0) == 0)
        try await Task.sleep(for: .seconds(1))   // the events of both arrive meanwhile
        #expect(tab.editor?.text == "aaaa\n")
        try "cccc\n".write(toFile: p, atomically: true, encoding: .utf8)   // a real change still shows
        for _ in 0..<100 where tab.editor?.text != "cccc\n" { try await Task.sleep(for: .milliseconds(50)) }
        #expect(tab.editor?.text == "cccc\n")
    }
}

/// A picture bigger than the window is shown smaller: it used to grow the window to its own size (#39).
@MainActor @Test func aBigImageDoesntGrowTheWindow() {
    let image = NSImage(size: NSSize(width: 6000, height: 4000))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
    let box = NSView(); window.contentView = box
    box.pin(ImagePreview(image: image, url: URL(fileURLWithPath: "/tmp/big.png")))
    window.layoutIfNeeded()
    #expect(window.contentLayoutRect.size == NSSize(width: 800, height: 600))
}
