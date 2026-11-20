import Core
import Foundation
import Testing

@testable import BuiltinRoutines

/// Berlin's calendar, weeks from Monday, and a reader of "yyyy-MM-dd HH:mm" in it.
private func berlin() throws -> (Calendar, (String) throws -> Date) {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
    cal.locale = Locale(identifier: "en_US")
    cal.firstWeekday = 2
    let f = DateFormatter()
    f.calendar = cal
    f.timeZone = cal.timeZone
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return (cal, { s in try #require(f.date(from: s)) })
}

/// The Routines tab's week: a day's runs as they went, and from now on when it's due — the next one marked.
@Test func aRoutinesWeekShowsRunsThenWhatsDue() throws {
    let (cal, at) = try berlin()
    let week = RoutineWeek(now: try at("2026-10-29 11:14"), calendar: cal)
    let monday = try at("2026-10-26 00:00")
    #expect(week.days.count == 7 && week.days.first == monday)
    let r = Routine(
        id: "r", name: "Morning triage", repoId: "p", agent: "claude", prompt: "x", every: .weekdays, time: 9 * 60)
    let wed = Routine.Run(
        routineId: "r", due: try at("2026-10-28 09:00"), outcome: .failed, summary: "gh is not signed in")
    #expect(week.marks(r, runs: [wed], day: week.days[2]).map(\.kind) == [.run(.failed)])
    #expect(week.marks(r, runs: [wed], day: week.days[3]).isEmpty)   // today's 9:00 has gone by without a run
    #expect(week.marks(r, runs: [], day: week.days[4]).map(\.kind) == [.next])
    #expect(week.marks(r, runs: [], day: week.days[5]).isEmpty)   // Saturday
    var off = r
    off.enabled = false
    #expect(week.marks(off, runs: [], day: week.days[4]).isEmpty)
    #expect(
        RoutineWeek.schedule(Routine(name: "h", repoId: "p", agent: "a", prompt: "x", every: .hourly, time: 15))
            == "Every hour at :15")
}

/// An hourly routine's day on the Routines tab: what ran stays as it went, the hours gone by without a run show
/// nothing, the very next one is marked as next and only it, the rest of today and all of tomorrow as planned.
@Test func anHourlyRoutinesDayMarksOnlyTheNextHourAsNext() throws {
    let (cal, at) = try berlin()
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
