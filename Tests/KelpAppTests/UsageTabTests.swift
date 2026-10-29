import Testing
@testable import BuiltinAgents

@Test func usageNamesClaudeModelsAsClaudeCodeDoes() {
    #expect(UsageReportView.model("claude-opus-5-5") == "Opus 5.5")
    #expect(UsageReportView.model("claude-haiku-4-5-20251001") == "Haiku 4.5")
    #expect(UsageReportView.model("claude-opus-5") == "Opus 5")
    #expect(UsageReportView.model("deepseek/deepseek-v4.1-flash-1017") == "deepseek/deepseek-v4.1-flash-1017")
}
