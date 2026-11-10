import Foundation
import Testing

@testable import Agents

/// A program with no "done" of its own (Codex at its prompt, herdr) ends a turn with idle: that's a finished turn, told as
/// one, and the idle that follows doesn't take it back. Idle before any work, after a question or a stop finished nothing.
@Test func idleAfterWorkIsAFinishedTurn() throws {
    var d = StatusDetector(manifest: try hooklessCodex())
    d.program("idle")
    #expect(d.status == .idle)
    d.program("working")
    d.program("idle")
    #expect(d.status == .done && d.source == "reported by the program: idle")
    d.program("idle")
    #expect(d.status == .done)
    d.program("clear")
    #expect(d.status == .idle)
    d.program("working")
    d.program("idle", cutShort: true)
    #expect(d.status == .idle)
    d.program("blocked")
    d.program("idle")
    #expect(d.status == .idle)
}

@Test func theStatusSaysWhereItCameFrom() throws {
    let t0 = Date()
    let codex = try hooklessCodex()
    var d = StatusDetector(manifest: codex)
    #expect(d.source == "the start")
    d.input()
    d.output("reading the project files", at: t0)
    #expect(d.source == "screen: it printed words")
    d.tick(at: t0.addingTimeInterval(4))
    #expect(d.source.hasPrefix("screen: quiet for"))
    d.program("blocked")
    #expect(d.source == "reported by the program: blocked")
    d.program("nonsense")   // changes nothing, so it isn't the source either
    #expect(d.source == "reported by the program: blocked")
    d.hook(.done)
    #expect(d.source == "hook: done")
    d.hook(.compacted)
    #expect(d.source == "hook: done")
    d.override(.working)
    #expect(d.source == "set by Kelp")
    d.override(.done, because: "no sign of life for 180 s")
    #expect(d.source == "no sign of life for 180 s")
    d.exited()
    d.override(.working)   // an ended program stays ended
    #expect(d.status == .exited && d.source == "the program ended")
}

/// Quiet is read off the clock that stands still while the Mac sleeps. Nothing here sleeps: if the detector kept the wall
/// clock's time of a line, the time on this one would be years before it, and the agent would never read as quiet.
@Test func quietIsMeasuredOnTheClockThatSleepsWithTheMac() {
    let manifest = AgentManifest(id: "a", name: "A", command: "a")
    var d = StatusDetector(manifest: manifest)
    d.input()
    d.output("it works on something")
    #expect(d.status == .working)
    #expect(d.tick(at: StatusDetector.clock.addingTimeInterval(manifest.quietSeconds + 1)) == .done)
}

/// What ends with no hook to say so doesn't hold a turn open: a memory save running at a Stop read as working for half an hour.
@Test func onlyWorkThatWakesTheAgentHoldsItsTurn() {
    var end = TurnEnd()
    for type in ["memory save", "dream", "auto-mode scan", "MCP task", "cloud session", "monitor", "something new"] {
        #expect(end.stop([.obj(["type": .string(type), "status": "running"])], goal: nil).0 == .done)
    }
    for type in ["subagent", "workflow", "teammate"] {
        #expect(end.stop([.obj(["type": .string(type), "status": "running"])], goal: nil).0 == .working)
    }
}
