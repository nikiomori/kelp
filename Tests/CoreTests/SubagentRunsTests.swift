import Foundation
import Testing
import Core

private func session() -> Session {
    var s = Session(cwd: "/", command: "claude")
    s.status = .working
    return s
}

@Test func aSubagentStaysOnTheRecordOnceItFinishes() {
    var s = session()
    s.subagents = ["a": "Explore"]
    s.subagentTasks = ["a": "Counts files"]
    s.subagents = ["a": "Explore", "b": ""]
    s.subagents = ["b": ""]
    s.subagentTasks = nil
    #expect(s.runningSubagents.map(\.id) == ["b"])
    #expect(s.finishedSubagents.map(\.task) == ["Counts files"])
    #expect(s.finishedSubagents.first?.ended != nil)
}

@Test func whoAsksComesFirstAndAFinishedOneAsksNoMore() {
    var s = session()
    s.subagents = ["a": ""]
    s.subagents = ["a": "", "b": ""]
    s.subagentsAsk(["b"])
    #expect(s.runningSubagents.map(\.id) == ["b", "a"])
    s.subagents = ["a": ""]
    #expect(s.finishedSubagents.first?.asks == nil)
    s.subagentsAsk(["b"])
    #expect(s.finishedSubagents.first?.asks == nil)
}

@Test func aTurnsEndTakesItsSubagentsAlong() {
    var s = session()
    s.subagents = ["a": ""]
    s.subagents = nil
    #expect(s.finishedSubagents.count == 1)
    s.status = .done
    #expect(s.subagentRuns == nil)
}

@Test func aLongTurnKeepsItsLastFinishedOnes() {
    var s = session()
    for i in 0..<40 {
        s.subagents = ["\(i)": ""]
        s.subagents = nil
    }
    s.subagents = ["last": ""]
    #expect(s.finishedSubagents.count == 32)
    #expect(s.finishedSubagents.last?.id == "39")
    #expect(s.runningSubagents.map(\.id) == ["last"])
}
