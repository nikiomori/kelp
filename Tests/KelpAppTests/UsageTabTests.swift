import Testing
@testable import BuiltinAgents

@Test func usageNamesClaudeModelsAsClaudeCodeDoes() {
    #expect(UsageReportView.model("claude-opus-5-5") == "Opus 5.5")
    #expect(UsageReportView.model("claude-haiku-4-5-20251001") == "Haiku 4.5")
    #expect(UsageReportView.model("claude-opus-5") == "Opus 5")
    #expect(UsageReportView.model("deepseek/deepseek-v4.1-flash-1017") == "deepseek/deepseek-v4.1-flash-1017")
}

@Test func yearBoardShadesDaysByQuarters() {
    let q = YearBoard.quarters([1, 2, 3, 4, 5, 6, 7, 8, 9])
    #expect(q == [3, 5, 7])
    #expect([0, 1, 3, 4, 6, 9].map { YearBoard.level($0, q) } == [0, 1, 1, 2, 3, 4])
    #expect(YearBoard.level(5, YearBoard.quarters([5])) == 1)   // one busy day is the lightest shade, not the darkest
}
