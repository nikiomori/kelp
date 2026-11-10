import Core
import Foundation
import Testing

@testable import BuiltinRoutines

/// An hourly routine's day on the Routines tab: what ran stays as it went, the hours gone by without a run show
/// nothing, the very next one is marked as next and only it, the rest of today and all of tomorrow as planned.
@Test func anHourlyRoutinesDayMarksOnlyTheNextHourAsNext() throws {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
    cal.locale = Locale(identifier: "en_US")
    cal.firstWeekday = 2
    let f = DateFormatter()
    f.calendar = cal
    f.timeZone = cal.timeZone
    f.dateFormat = "yyyy-MM-dd HH:mm"
    func at(_ s: String) throws -> Date { try #require(f.date(from: s)) }
    let week = RoutineWeek(now: try at("2026-10-29 11:14"), calendar: cal)   // a Thursday
    let r = Routine(id: "r", name: "Sweep", repoId: "p", agent: "claude", prompt: "x", every: .hourly, time: 15)
    let ran = Routine.Run(routineId: "r", due: try at("2026-10-29 09:15"), outcome: .failed, summary: "")
    let other = Routine.Run(routineId: "o", due: try at("2026-10-29 10:15"), outcome: .failed, summary: "")
    let today = week.marks(r, runs: [ran, other], day: week.days[3])
    #expect(today.first?.kind == .run(.failed) && today.first?.at == ran.due)   // another routine's run isn't its
    #expect(today.dropFirst().map(\.at) == (try (11...23).map { try at("2026-10-29 \($0):15") }))
    #expect(today.dropFirst().map(\.kind) == [.next] + Array(repeating: .planned, count: 12))
    #expect(Set(today.map(\.id)).count == today.count)   // each mark its own id: SwiftUI draws them by it
    let tomorrow = week.marks(r, runs: [], day: week.days[4])
    #expect(tomorrow.count == 24 && tomorrow.allSatisfy { $0.kind == .planned })
    var weekly = r
    weekly.every = .weekly
    weekly.weekday = 2
    weekly.time = 10 * 60
    #expect(RoutineWeek.schedule(weekly, calendar: cal).hasPrefix("Mondays at "))
}
