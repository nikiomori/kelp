import AppKit
import Foundation
import Testing

@testable import BuiltinAgents

/// ⌘ held over a path the terminal opens shows the file and line ⌘-click opens (`PaneView`'s `onPathAt`); a word, a
/// missing file or a page Ghostty links itself shows nothing.
@MainActor
@Test func commandOverAPathShowsWhatItOpens() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pill-\(UUID().uuidString)")
    let file = dir.appendingPathComponent("Sources/App.swift")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try "".write(to: file, atomically: true, encoding: .utf8)
    let shown = ((file.path as NSString).standardizingPath as NSString).abbreviatingWithTildeInPath
    let cases: [([String], String?)] = [
        (["Sources/App.swift:12:5"], shown + ":12"),
        (["Sources/Gone.swift", "Sources/App.swift"], shown),   // the first reading that is a file
        (["Sources/Gone.swift:3"], nil),
        (["hello"], nil),
        (["https://example.com/Sources/App.swift"], nil)
    ]
    for (tokens, expected) in cases {
        #expect(TerminalPaths.shown(tokens, cwd: dir.path) == expected, "\(tokens)")
    }
}

/// The pill shows the address it's given and goes on "", and clicks go through it to the terminal.
@MainActor
@Test func theLinkPillShowsAnAddressAndGoes() {
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)), bottom = NSView()
    host.addSubview(bottom)
    let pill = LinkPill(in: host, above: bottom)
    pill.show("~/kelp/Sources/App.swift:12")
    #expect(!pill.isHidden && pill.label.stringValue == "~/kelp/Sources/App.swift:12")
    #expect(pill.hitTest(NSPoint(x: 1, y: 1)) == nil)
    pill.show("")
    #expect(pill.isHidden)
}
