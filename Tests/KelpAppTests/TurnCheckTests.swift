import Testing

@testable import BuiltinFiles

/// After a turn, only what the turn brought is told, once; the check of a turn Kelp's own message started is not told
/// again, and a check with no turn before it tells nothing.
@MainActor @Test func aTurnsNewIssuesAreToldOnce() {
    let check = TurnCheck()
    #expect(check.checked(["old"]).isEmpty, "no turn yet")
    check.agent(working: true, issues: ["old"])
    check.agent(working: false, issues: nil)
    #expect(check.checked(["old", "cut off"]) == ["cut off"])
    #expect(check.checked(["old", "cut off"]).isEmpty, "once per turn")
    check.agent(working: true, issues: ["old", "cut off"])   // the turn Kelp's message started
    check.agent(working: false, issues: nil)
    #expect(check.checked(["old", "contrast"]).isEmpty, "not told about its own fixing turn")
    check.agent(working: true, issues: ["old", "contrast"])
    check.agent(working: false, issues: nil)
    #expect(check.checked(["old", "contrast", "cut off", "font"]) == ["font"], "what was told stays told")
}
