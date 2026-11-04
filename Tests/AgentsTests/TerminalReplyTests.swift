import Foundation
import Testing
@testable import Agents

/// Claude Code asks the terminal at start whether it shows images (kitty graphics): replayed, the question goes; the
/// answer is the terminal talking, not a key, which would count as answering "trust this folder?".
@Test func imageQuestionsAndAnswersAreNotTyping() {
    let image = Data("a\u{1B}_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\u{1B}\\b".utf8)   // Claude Code asks it at start
    #expect(String(bytes: TerminalReplies.withoutQueries(image), encoding: .utf8) == "ab")
    #expect(TerminalReplies.isReply(Data("\u{1B}_Gi=31;OK\u{1B}\\".utf8)))
    #expect(TerminalReplies.isReply(Data("\u{1B}_Gi=31;EINVAL:unsupported\u{1B}\\\u{1B}[?62;22c".utf8)))
}
