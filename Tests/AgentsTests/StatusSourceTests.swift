import Foundation
import Testing
@testable import Agents

@Test func theStatusSaysWhereItCameFrom() throws {
    let t0 = Date()
    let codex = try #require(AgentManifest.presets.first { $0.id == "codex" })
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
    d.hook("done")
    #expect(d.source == "hook: done")
    d.hook("compacted")
    #expect(d.source == "hook: done")
    d.override(.working)
    #expect(d.source == "set by Kelp")
    d.exited()
    d.override(.working)   // an ended program stays ended
    #expect(d.status == .exited && d.source == "the program ended")
}
