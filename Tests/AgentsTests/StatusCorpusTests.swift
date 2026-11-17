import Core
import Foundation
import Testing

@testable import Agents

/// A hookless agent's borders and a spinner with no words around it start no turn: a welcome box before any input, a
/// redrawn frame after it.
@Test func bordersAndSpinnersWithoutWordsStartNothing() throws {
    let aider = try #require(AgentManifest.presets.first { $0.id == "aider" })
    var d = StatusDetector(manifest: aider)
    let t0 = Date()
    d.output("╭──────────────╮\r\n│ >            │\r\n╰──────────────╯", at: t0)
    d.input(at: t0.addingTimeInterval(1))
    d.output("│ ⠙ │", at: t0.addingTimeInterval(3.5))
    d.tick(at: t0.addingTimeInterval(8))
    #expect(d.status == .idle)
}
