import Core
import Foundation
import Testing

@testable import KelpKit

@Test func aReminderIsForTheQuestionItWasSetFor() {
    let at = Date()
    var asked = Session(cwd: "/", command: "x", agent: "claude", status: .waiting, unread: true, summary: "Allow rm?")
    asked.statusAt = at
    var now = asked
    #expect(QuestionReminder.stillStands(asked, now: now))
    #expect(!QuestionReminder.stillStands(asked, now: nil))
    now.status = .working
    #expect(!QuestionReminder.stillStands(asked, now: now))   // answered
    now.status = .waiting
    now.statusAt = at.addingTimeInterval(60)
    #expect(!QuestionReminder.stillStands(asked, now: now))   // the next question counts for itself
}
