import Foundation
import Testing
@testable import Core

/// Claude Code 2.1's hook payloads for Bash, as `claude -p` sent them (trimmed to what's read).
private func payload(_ json: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) }

@Test func aBashCommandStartsWithItsPreToolUseAndEndsWithItsPostToolUse() throws {
    let now = Date()
    let start = try #require(AgentCommand(hook: try payload("""
        {"hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"echo hello","description":"Print hello"}}
        """), now: now))
    #expect(start.id == "t1" && start.command == "echo hello" && start.description == "Print hello" && start.outcome == nil && start.ended == nil)
    let end = try #require(AgentCommand(hook: try payload("""
        {"hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"echo hello"},
         "tool_response":{"stdout":"hello","stderr":"","interrupted":false},"duration_ms":2500}
        """), now: now))
    #expect(end.outcome == .ok && end.exitCode == 0 && end.output == "hello" && end.ended == now)
    #expect(end.started == now.addingTimeInterval(-2.5))
}

@Test func aFailedBashCommandSaysItsExitCodeAndWhatItPrinted() throws {
    let failed = try #require(AgentCommand(hook: try payload("""
        {"hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_use_id":"t2","tool_input":{"command":"ls /none"},
         "error":"Exit code 1\\nls: /none: No such file or directory","is_interrupt":false}
        """)))
    #expect(failed.outcome == .failed && failed.exitCode == 1 && failed.output == "ls: /none: No such file or directory")
    let refused = try #require(AgentCommand(hook: try payload("""
        {"hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_use_id":"t3","tool_input":{"command":"rm -rf x"},"error":"Denied"}
        """)))
    #expect(refused.outcome == .failed && refused.exitCode == nil && refused.output == "Denied")
    let interrupted = try #require(AgentCommand(hook: try payload("""
        {"hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_use_id":"t4","tool_input":{"command":"sleep 9"},"error":"","is_interrupt":true}
        """)))
    #expect(interrupted.outcome == .stopped && interrupted.output == nil)
}

@Test func aBackgroundBashCommandIsntTakenForEnded() throws {
    let bg = try #require(AgentCommand(hook: try payload("""
        {"hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"t5","tool_input":{"command":"npm run dev","run_in_background":true},
         "tool_response":{"stdout":"","stderr":"","interrupted":false,"backgroundTaskId":"bip12"}}
        """)))
    #expect(bg.outcome == .background && bg.exitCode == nil && bg.output == nil)
    // Other tools, and a payload without its command, aren't commands.
    #expect(AgentCommand(hook: try payload(#"{"hook_event_name":"PreToolUse","tool_name":"Read","tool_use_id":"t6","tool_input":{"file_path":"/a"}}"#)) == nil)
    #expect(AgentCommand(hook: try payload(#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"t7"}"#)) == nil)
}

@Test func aLongOutputKeepsItsEndAndACommandItsCd() {
    let long = String(repeating: "x", count: AgentCommand.outputLimit) + "END"
    #expect(AgentCommand.tail(long)?.hasSuffix("END") == true && AgentCommand.tail(long)?.utf8.count == AgentCommand.outputLimit)
    #expect(AgentCommand.tail("") == nil)
    #expect(AgentCommand.short("cd /Users/me/project && swift test --filter A") == "swift test --filter A")
    #expect(AgentCommand.short(#"cd "/a b" && make"#) == "make")
    #expect(AgentCommand.short("cd sub") == "cd sub")
}
