import AppKit
import GhosttyKit
import Testing
@testable import TerminalKit

/// Tests that start a terminal take turns: two logins started at once can fail, and Ghostty then prints "failed to launch
/// the requested command" over what the program shows (it did on CI).
@MainActor private var terminalTaken = false
@MainActor private func takeTerminal() async throws {
    while terminalTaken { try await Task.sleep(for: .milliseconds(20)) }
    terminalTaken = true
}

/// A terminal closed while programs set titles (an agent's replayed history has thousands): each is a message in the app's
/// mailbox, which only a tick on the main thread empties, so freeing the surface there waited for itself. The app stopped
/// for good, so a hang here ends the run instead of holding it up.
@Test @MainActor func closingATerminalLeavesTheAppRunning() async throws {
    try await takeTerminal(); defer { terminalTaken = false }
    let finished = DispatchSemaphore(value: 0)
    defer { finished.signal() }
    Thread.detachNewThread { if finished.wait(timeout: .now() + 45) == .timedOut { fatalError("closing a terminal held the main thread") } }
    let script = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-titles-\(UUID().uuidString).sh")
    try #"while :; do printf '\033]0;a title\007'; done"#.write(to: script, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: script) }
    var closing: GhosttyTerminalView? = GhosttyTerminalView(command: "/bin/sh " + script.path, cwd: NSTemporaryDirectory())
    let stays = GhosttyTerminalView(command: "/bin/sh " + script.path, cwd: NSTemporaryDirectory())
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    w.contentView = NSView(frame: w.contentLayoutRect)
    try w.contentView?.addSubview(#require(closing)); w.contentView?.addSubview(stays)
    w.orderFront(nil)
    defer { w.orderOut(nil) }
    var titles = 0
    closing?.onTitle = { _ in titles += 1 }
    stays.onTitle = { _ in titles += 1 }
    let started = Date() + 15
    while titles < 500, Date() < started { try await Task.sleep(for: .milliseconds(20)) }
    #expect(titles >= 500)
    closing?.removeFromSuperview()
    closing = nil
    let closed = Date() + 15   // a program that went on printing would never let it go
    repeat { try await Task.sleep(for: .milliseconds(20)) } while GhosttyRuntime.shared.retiring > 0 && Date() < closed
    #expect(GhosttyRuntime.shared.retiring == 0)
    let before = titles
    try await Task.sleep(for: .milliseconds(200))
    #expect(titles > before)   // the one left goes on
}

@Test func copyLeavesTheTUIBehind() {
    // An agent's gutter and padding to the right edge.
    #expect(TerminalCopy.clean("  func a() {   \n      return 1\n  }  ") == "func a() {\n    return 1\n}")
    // A box: its sides go, the text stays.
    #expect(TerminalCopy.clean("│ npm test   │\n│ 3 passed   │") == "npm test\n3 passed")
    // Plain text is untouched.
    #expect(TerminalCopy.clean("a b\nc") == "a b\nc")
}

/// A command Claude Code wrapped in its gutter (wrap-ansi, `hard`, `trim: false`, 30 columns in a 32-column terminal),
/// copied from its first character: one line again.
let wrappedCommand = "! cd /Users/username/projects/Kelp && swift build -c release --product kelp && swift test --parallel --quiet"
    + #" && (git cat-file -e 4b825dc642cb6eb9a060e54bf8d69288fbee4904 2>/dev/null && echo "дерево есть" || echo "пустого дерева нет")"#
let wrappedRows = ["! cd ", "/Users/username/projects/Kelp ", "&& swift build -c release ", "--product kelp && swift test ",
                   "--parallel --quiet && (git ", "cat-file -e 4b825dc642cb6eb9a0", "60e54bf8d69288fbee4904 ",
                   #"2>/dev/null && echo "дерево "#, #"есть" || echo "пустого дерева "#, #"нет")"#]

@Test func copyJoinsRowsAProgramWrapped() {
    let copied = wrappedRows.enumerated().map { $0 == 0 ? $1 : "  " + $1 }.joined(separator: "\n")   // the selection's first row starts past the gutter
    #expect(TerminalCopy.clean(copied, from: 2, columns: 32) == wrappedCommand)
    #expect(TerminalCopy.clean("  " + copied, columns: 32) == wrappedCommand)   // from the row's start
    #expect(TerminalCopy.clean(copied, from: 2).components(separatedBy: "\n").count == wrappedRows.count)   // no width, no joins
    // Lines that ended before the edge stay apart; so does output without a gutter (`ls` pads its columns to the edge).
    #expect(TerminalCopy.clean("  short\n  lines", columns: 32) == "short\nlines")
    #expect(TerminalCopy.clean("aaaa  bbbb  cccc\ndddd", columns: 17) == "aaaa  bbbb  cccc\ndddd")
    // A selection that starts mid-row keeps its first line as copied, and its rows lose the gutter.
    #expect(TerminalCopy.clean("run:\n  next", from: 6, columns: 80) == "run:\nnext")
}

@Test func wordsKeepTheirLineNumbers() {
    let line = "  Edited Sources/App.swift:12:5, see (docs/x.md)."
    #expect(TerminalCopy.word(in: line, at: 12)?.text == "Sources/App.swift:12:5")
    #expect(TerminalCopy.word(in: line, at: 12)?.start == 9)
    #expect(TerminalCopy.word(in: line, at: 40)?.text == "docs/x.md")
    #expect(TerminalCopy.word(in: line, at: 1) == nil)
}

/// A word that runs to the right edge goes on at the next row's first word, as Claude Code breaks a long path.
@Test func wordsGoOnAcrossWrappedRows() {
    func at(_ rows: [String], _ row: Int, _ col: Int, columns: Int = 14) -> [String]? {
        TerminalCopy.wrappedWord(rows: { rows.indices.contains($0) ? rows[$0] : nil }, row: row, at: col, columns: columns)?.texts
    }
    let rows = ["  see /tmp/abc", "  def/x.png.", "  word", "  /tmp/full.md", "  next one"]
    #expect(at(rows, 0, 8) == ["/tmp/abcdef/x.png", "/tmp/abc"])         // from its first row
    #expect(at(rows, 1, 3) == ["/tmp/abcdef/x.png", "def/x.png"])        // and from the row it went on to
    #expect(at(rows, 0, 3) == ["see"])                                   // not the row's last word
    #expect(at(rows, 2, 3) == ["word"])                                  // a row short of the edge ends its word
    #expect(at(rows, 3, 3) == ["/tmp/full.mdnext", "/tmp/full.md"])      // a word that just filled its row: its own too
    #expect(at(["aaaa", "bbbb", "cc"], 2, 0, columns: 4) == ["aaaabbbbcc", "cc"])   // over three rows
}

/// A path and a link a program broke at the right edge itself (no soft wrap Ghostty knows of): ⌘-click on their last
/// row gets all of them.
@Test @MainActor func commandClickJoinsRowsAProgramBroke() async throws {
    try await takeTerminal(); defer { terminalTaken = false }
    let path = "/tmp/" + String(repeating: "a", count: 150) + "/x.txt", link = "https://example.com/" + String(repeating: "b", count: 100) + "?q=1"
    let script = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-wrap-\(UUID().uuidString).sh")
    try #"sleep 0.5; c=$(stty size | cut -d' ' -f2); printf '\033[?1000h\033[?1006h'; for s in '\#(path)' '\#(link)'; do printf '%s\n' "$s" | fold -w "$c"; done; echo DONE; sleep 20"#
        .write(to: script, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: script) }
    let v = GhosttyTerminalView(command: "/bin/sh " + script.path, cwd: NSTemporaryDirectory())
    let surface = try #require(v.surface)
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    w.contentView = v; w.orderFront(nil)
    defer { w.orderOut(nil) }
    var tried: [String] = [], opened: URL?
    v.onOpenPath = { t, _ in tried.append(t); return t == path }
    v.onOpenURL = { opened = $0 }
    let deadline = Date() + 15
    while !(v.visibleText.contains("DONE") && ghostty_surface_mouse_captured(surface)), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    let rows = v.visibleText.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    let s = ghostty_surface_size(surface), scale = w.backingScaleFactor
    let cw = Double(s.cell_width_px) / scale, ch = Double(s.cell_height_px) / scale
    func click(lastRowOf text: String) throws {
        let row = try #require(rows.firstIndex { !$0.isEmpty && $0.count < text.count && text.hasSuffix($0) })
        let p = v.convert(NSPoint(x: 12 + 0.5 * cw, y: v.bounds.height - 8 - (Double(row) + 0.5) * ch), to: nil)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = try #require(NSEvent.mouseEvent(with: t, location: p, modifierFlags: .command, timestamp: 0, windowNumber: w.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if t == .leftMouseDown { v.mouseDown(with: e) } else { v.mouseUp(with: e) }
        }
    }
    try click(lastRowOf: path)
    #expect(tried.first == path, "\(rows)")
    try click(lastRowOf: link)
    #expect(opened?.absoluteString == link, "\(rows)")
}

/// The same command on screen, selected from its first character and copied with ⌘C: Ghostty's selection gives the column.
@Test @MainActor func copyingAWrappedCommandGivesOneLine() async throws {
    try await takeTerminal(); defer { terminalTaken = false }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-rows-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try (wrappedRows.map { "  " + $0 }.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("rows"), atomically: true, encoding: .utf8)
    try "clear; cat rows; echo DONE; sleep 20".write(to: dir.appendingPathComponent("show.sh"), atomically: true, encoding: .utf8)
    let v = GhosttyTerminalView(command: "/bin/sh show.sh", cwd: dir.path)
    let surface = try #require(v.surface)
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    w.contentView = v; w.orderFront(nil)
    defer { w.orderOut(nil) }
    let deadline = Date() + 15   // a loaded CI runner can take seconds to start the shell
    while !v.visibleText.contains("DONE"), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    let s = ghostty_surface_size(surface), scale = w.backingScaleFactor
    try #require(s.columns == 32)
    let cw = Double(s.cell_width_px) / scale, ch = Double(s.cell_height_px) / scale
    let screen = v.visibleText.components(separatedBy: "\n")
    let first = try #require(screen.firstIndex { $0.hasPrefix("  ! cd") }), last = first + wrappedRows.count - 1
    func at(_ col: Double, _ row: Int) -> NSPoint { v.convert(NSPoint(x: 12 + col * cw, y: v.bounds.height - 8 - (Double(row) + 0.5) * ch), to: nil) }
    func send(_ t: NSEvent.EventType, _ p: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    v.mouseMoved(with: try send(.mouseMoved, at(2.2, first)))
    v.mouseDown(with: try send(.leftMouseDown, at(2.2, first)))
    v.mouseDragged(with: try send(.leftMouseDragged, at(31.8, last)))
    v.mouseUp(with: try send(.leftMouseUp, at(31.8, last)))
    let pb = NSPasteboard.general, kept = pb.string(forType: .string)
    defer { pb.clearContents(); if let kept { pb.setString(kept, forType: .string) } }
    let before = pb.changeCount
    v.copy(nil)
    while pb.changeCount == before, Date() < deadline + 2 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(pb.string(forType: .string) == wrappedCommand)
}

@Test func wideCharactersTakeTwoColumns() {
    let line = "日本 src/a.swift"   // 日本 covers columns 0-3, the path starts at 5
    #expect(TerminalCopy.word(in: line, at: 6)?.text == "src/a.swift")
    #expect(TerminalCopy.word(in: line, at: 6)?.start == 5)
    #expect(TerminalCopy.word(in: line, at: 1)?.width == 4)
    #expect(TerminalCopy.word(in: line, at: 4) == nil)
}

@MainActor
/// Programs may copy (OSC 52: Claude Code over ssh), flagged so that `confirmClipboard` keeps those lines from running on
/// ⌘V where pastes aren't bracketed — which needs paste protection on.
@Test func programCopiesAreFlagged() throws {
    #expect(GhosttyRuntime.overrides.contains("clipboard-write = ask"))
    #expect(GhosttyRuntime.overrides.contains("clipboard-paste-protection = true"))
    // And Ghostty takes every line of Kelp's settings (a wrong key or value would be dropped with a diagnostic).
    try #require(ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS)   // config needs it; no app
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-overrides-\(UUID().uuidString).conf")
    try GhosttyRuntime.overrides.write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }
    let cfg = ghostty_config_new()
    ghostty_config_load_file(cfg, file.path); ghostty_config_finalize(cfg)
    let problems = (0..<ghostty_config_diagnostics_count(cfg)).map { String(cString: ghostty_config_get_diagnostic(cfg, $0).message) }
    ghostty_config_free(cfg)
    #expect(problems.isEmpty, "\(problems)")
}

@Test @MainActor func pasteTypesAnImageAsItsPath() throws {
    let pb = NSPasteboard(name: .init("kelp-test-\(UUID().uuidString)"))
    defer { pb.releaseGlobally() }
    let img = NSImage(size: NSSize(width: 4, height: 4))
    img.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); img.unlockFocus()
    // A screenshot (an image and no text): a PNG on disk, typed as its path.
    pb.clearContents(); pb.writeObjects([img])
    let typed = try #require(TerminalPaste.text(from: pb))
    #expect(typed.hasSuffix(".png "))
    #expect(NSImage(contentsOfFile: String(typed.dropLast())) != nil)
    // Text wins over an image that came with it (a table copied from a spreadsheet).
    pb.clearContents(); pb.writeObjects([img, "a b" as NSString])
    #expect(TerminalPaste.text(from: pb) == "a b")
    // A file copied in Finder: its path, escaped, not just its name.
    pb.clearContents(); pb.writeObjects([URL(fileURLWithPath: "/tmp/my shot.png") as NSURL])
    #expect(TerminalPaste.text(from: pb) == "/tmp/my\\ shot.png ")
}

/// A program that takes paste events (omp) is offered what ⌘V would type, and reads it by MIME type.
@Test @MainActor func pasteEventsListWhatAPasteWouldType() throws {
    let pb = NSPasteboard(name: .init("kelp-test-\(UUID().uuidString)"))
    defer { pb.releaseGlobally() }
    let img = NSImage(size: NSSize(width: 4, height: 4))
    img.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); img.unlockFocus()
    pb.clearContents(); pb.writeObjects(["привет" as NSString])
    #expect(TerminalPaste.mimes(pb) == ["text/plain"])
    #expect(TerminalPaste.data(pb, mime: "text/plain") == Data("привет".utf8))
    #expect(TerminalPaste.data(pb, mime: "text/html") == nil)
    // Text wins over the picture of it; an image alone is offered as one.
    pb.clearContents(); pb.writeObjects([img, "a b" as NSString])
    #expect(TerminalPaste.mimes(pb) == ["text/plain"])
    pb.clearContents(); pb.writeObjects([img])
    #expect(TerminalPaste.mimes(pb) == ["text/plain", "image/png"])
    let png = try #require(TerminalPaste.data(pb, mime: "image/png"))
    #expect(NSBitmapImageRep(data: png) != nil)
    pb.clearContents()
    #expect(TerminalPaste.mimes(pb).isEmpty)
}

/// ⌘ over a program that took the mouse gets ⇧, which is how Ghostty looks for links past the capture; nothing else changes.
@Test func commandFindsLinksPastMouseCapture() {
    let g = GhosttyTerminalView.self
    #expect(g.linkMods(.command, captured: true) == [.command, .shift])
    #expect(g.linkMods([.command, .capsLock], captured: true) == [.command, .capsLock, .shift])
    #expect(g.linkMods(.command, captured: false) == .command)   // a shell prompt: Ghostty wants ⌘ alone
    #expect(g.linkMods([.command, .option], captured: true) == [.command, .option])
    #expect(g.linkMods([], captured: true) == [])
}

/// A program that takes the mouse (as Claude Code does) and prints a link: ⌘-click on it opens its whole target.
@Test @MainActor func commandClickOpensALinkUnderMouseCapture() async throws {
    try await takeTerminal(); defer { terminalTaken = false }
    let script = #"printf '\033[?1000h\033[?1006h\033]8;;https://example.com/a?b=c\033\\LINKTEXT\033]8;;\033\\\n'; sleep 20"#
    let v = GhosttyTerminalView(command: script, cwd: NSTemporaryDirectory())
    let surface = try #require(v.surface)
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    w.contentView = v; w.orderFront(nil)
    defer { w.orderOut(nil) }
    var opened: URL?
    v.onOpenURL = { opened = $0 }
    let deadline = Date() + 15
    while !(v.visibleText.contains("LINKTEXT") && ghostty_surface_mouse_captured(surface)), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    let rows = v.visibleText.components(separatedBy: "\n")
    let row = try #require(rows.firstIndex { $0.contains("LINKTEXT") })
    let s = ghostty_surface_size(surface), scale = w.backingScaleFactor
    let cw = Double(s.cell_width_px) / scale, ch = Double(s.cell_height_px) / scale
    let p = v.convert(NSPoint(x: 12 + 3.5 * cw, y: v.bounds.height - 8 - (Double(row) + 0.5) * ch), to: nil)
    func send(_ t: NSEvent.EventType, _ mods: NSEvent.ModifierFlags, dx: Double = 0) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: t, location: NSPoint(x: p.x + dx, y: p.y), modifierFlags: mods, timestamp: 0, windowNumber: w.windowNumber,
                                        context: nil, eventNumber: 0, clickCount: t == .mouseMoved ? 0 : 1, pressure: 1))
    }
    v.mouseMoved(with: try send(.mouseMoved, [], dx: -3))
    v.mouseMoved(with: try send(.mouseMoved, .command))
    v.mouseDown(with: try send(.leftMouseDown, .command)); v.mouseUp(with: try send(.leftMouseUp, .command))
    #expect(opened?.absoluteString == "https://example.com/a?b=c")
}

/// Dictation apps (MacWhisper) paste only into a focused text area: the terminal is one, its screen the value and its
/// cursor the caret — where Pretype finds an agent's input box (the text up to the caret, a rule on the row under it).
@Test @MainActor func terminalIsATextAreaToAccessibility() async throws {
    try await takeTerminal(); defer { terminalTaken = false }
    let rule = String(repeating: "─", count: 30)
    let script = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-box-\(UUID().uuidString).sh")
    try "clear; printf 'SPOKEN\\n\(rule)\\n❯ 世界 fix\\n\(rule)\\n\\033[3;11H'; sleep 20".write(to: script, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: script) }
    let v = GhosttyTerminalView(command: "/bin/sh " + script.path, cwd: NSTemporaryDirectory())
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    w.contentView = v; w.orderFront(nil)
    defer { w.orderOut(nil) }
    let deadline = Date() + 15
    while !(v.visibleText.contains("fix") && v.screen().cursor?.row == 2), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    #expect(v.isAccessibilityElement() && v.accessibilityRole() == .textArea && v.accessibilityIdentifier() == "terminal")
    let text = try #require(v.accessibilityValue() as? String) as NSString
    #expect(text.hasPrefix("SPOKEN") && text.length == v.accessibilityNumberOfCharacters())
    let caret = v.accessibilitySelectedTextRange()
    #expect(caret.length == 0 && text.substring(to: caret.location).hasSuffix("\(rule)\n❯ 世界 fix"), "wide characters are a cell each in the text")
    #expect(v.accessibilityString(for: NSRange(location: caret.location, length: 31)) == "\n" + rule)
    #expect(v.accessibilityString(for: NSRange(location: text.length, length: 1)) == nil)
    let s = try #require(v.surface.map(ghostty_surface_size)), scale = w.backingScaleFactor
    let cell = w.convertToScreen(v.convert(NSRect(x: 12 + 10 * Double(s.cell_width_px) / scale, y: v.bounds.height - 8 - 3 * Double(s.cell_height_px) / scale,
                                                 width: 0, height: Double(s.cell_height_px) / scale), to: nil))
    #expect(v.accessibilityFrame(for: caret) == cell, "the cursor's cell, after the two wide characters")
}
