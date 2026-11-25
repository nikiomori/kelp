import AppKit
import Foundation
import Testing

@testable import BuiltinAgents
@testable import Core
@testable import KelpKit

// Agents Kelp's going down cut short: what offers to continue them, and how their pane and mark show them.

/// The banner offers all the agents cut short when any is news, once, and nothing when they go on by themselves.
@MainActor @Test func continueAllIsOfferedOnceForAgentsCutShort() {
    let cases: [([String], Set<String>, Bool, [String])] = [
        (["a", "b"], [], false, ["a", "b"]),
        (["a", "b"], ["a", "b"], false, []),   // shown already (a reconnect to the same daemon)
        (["a", "c"], ["a", "b"], false, ["a", "c"]),   // one more cut short: the banner names all again
        (["a"], [], true, []),   // they go on by themselves (the setting)
        ([], [], false, [])
    ]
    for (cut, told, byThemselves, offered) in cases {
        #expect(InterruptedAgents.toOffer(cut, told: told, goOnByThemselves: byThemselves) == offered, "\(cut) \(told)")
    }
}

/// The pane of an agent cut short shows what it printed last, read from its log, without waking it.
@MainActor @Test func aPaneShowsWhatAnAgentCutShortPrintedLast() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("history"), withIntermediateDirectories: true)
    try Data("⏺ Writing the migration\r\n  ⎿ Interrupted\r\n".utf8).write(
        to: root.appendingPathComponent("history/s1.log"))
    let shell = Process(), out = Pipe()
    shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
    shell.arguments = ["-c", PaneView.replayCommand("s1", root: root)]
    shell.standardOutput = out
    try shell.run()
    shell.waitUntilExit()
    let printed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(shell.terminationStatus == 0 && printed.hasSuffix("⏺ Writing the migration\r\n  ⎿ Interrupted\r\n"))
}

/// The bar under a paused agent says when Kelp closed and offers Continue, for one it cut short; any other paused agent
/// is just paused, with Resume.
@MainActor @Test func theBarOfAnAgentCutShortSaysWhenKelpClosed() {
    var cut = Session(cwd: "/tmp", command: "claude", agent: "claude", status: .paused)
    let paused = PaneView.pausedWords(cut)
    #expect(PaneView.pausedButton(cut) == "Resume")
    cut.interruptedAt = Date(timeIntervalSince1970: 0)
    let words = PaneView.pausedWords(cut)
    #expect(words != paused && words.contains(cut.interruptedAt?.formatted(date: .omitted, time: .shortened) ?? "-"))
    #expect(PaneView.pausedButton(cut) == "Continue")
}

/// The mark of an agent cut short and not looked at yet turns back instead of sleeping.
@MainActor @Test func theMarkOfAnAgentCutShortIsItsOwn() {
    let mark = StatusMark(size: 12)
    mark.status = .paused
    let asleep = mark.toolTip
    var cut = Session(cwd: "/tmp", command: "claude", agent: "claude", status: .paused, unread: true)
    cut.interruptedAt = Date()
    mark.follow(cut)
    #expect(mark.toolTip != asleep && !mark.isHidden)
}
