import Core
import Foundation
import Testing

@testable import Agents

/// What hookless agents print, as they print it (chunks a read hands over, at the times they come), and the status the
/// screen gives: a turn, a question, the user typing, the redraws that follow a turn, a re-attach, a split title.
private enum Step { case typed(String), sent(String), out(String), tick }

private func replay(_ agent: String, _ steps: [(at: Double, Step)]) -> AgentStatus {
    var m = AgentManifest.presets.first { $0.id == agent } ?? AgentManifest(id: agent, name: agent, command: agent)
    if m.hooks == .codexConfig { m.hooks = nil }   // recorded before Codex had Kelp's hooks: its screen alone
    var d = StatusDetector(manifest: m)
    let t0 = Date()
    for (at, step) in steps {
        let now = t0.addingTimeInterval(at)
        switch step {
        case .typed: d.input(typing: true, at: now)
        case .sent: d.input(at: now)
        case .out(let s): d.output(s, at: now)
        case .tick: d.tick(at: now)
        }
    }
    return d.status
}

@Test func codexWorkingThenDone() {
    var steps: [(Double, Step)] = [(0, .sent("fix the login bug\r"))]
    for i in 0..<4 {
        steps.append((2.5 + Double(i), .out("\u{1B}]0;\(["⠋", "⠙", "⠹", "⠸"][i]) Fix the login bug | shop\u{07}")))
    }
    #expect(replay("codex", steps + [(4, .tick)]) == .working)   // only a spinning title: still its work
    steps += [(6, .out("• Updated src/login.ts (+12 -3)\r\n")), (6.2, .out("\u{1B}]0;shop\u{07}"))]
    #expect(replay("codex", steps + [(10, .tick)]) == .done)
}

@Test func aQuestionAtTheEndOfATurnIsWaiting() {
    let steps: [(Double, Step)] = [
        (0, .sent("migrate the db\r")),
        (3, .out("I'll run the migration first.\r\n")),
        (3.4, .out("Do you want to run `rake db:migrate`? [y/N] ")),
        (7, .tick)
    ]
    #expect(replay("gemini", steps) == .waiting)
}

@Test func theUsersOwnTypingIsNoWork() {
    let steps: [(Double, Step)] = [
        (0, .typed("hello wor")), (0.3, .out("hello wor")), (1, .typed("ld")), (1.2, .out("ld")), (5, .tick)
    ]
    #expect(replay("aider", steps) == .idle)
}

@Test func theRedrawAfterATurnIsNoNewTurn() {
    let steps: [(Double, Step)] = [
        (0, .sent("go\r")), (3, .out("Reading the files now\r\n")), (7, .tick),   // done
        (8, .out("\u{1B}[2K✻ Worked for 5.5s\r\n")), (12, .tick)
    ]
    #expect(replay("aider", steps) == .done)
}

@Test func bordersAndSpinnersWithoutWordsStartNothing() {
    let steps: [(Double, Step)] = [
        (0, .out("╭──────────────╮\r\n│ >            │\r\n╰──────────────╯")),   // a welcome box before any input
        (1, .sent("go\r")), (3.5, .out("│ ⠙ │")), (8, .tick)
    ]
    #expect(replay("aider", steps) == .idle)
}

@Test func aSplitTitleWhileIdleIsNoTurn() {
    let steps: [(Double, Step)] = [
        (0, .sent("go\r")), (3, .out("All done here\r\n")), (7, .tick),
        (12, .out("\u{1B}]0;Waiting for your next")), (12.1, .out(" request in the shop\u{07}")), (16, .tick)
    ]
    #expect(replay("aider", steps) == .done)
}
