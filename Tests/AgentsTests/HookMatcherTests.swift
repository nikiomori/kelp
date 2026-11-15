import Core
import Foundation
import Testing

@testable import Agents

/// A tool's end runs `kelp hook command` only for the tools something reads it of (a command, a file edited, a page
/// published, a worktree entered): every one of those, none of the reading tools an agent calls most.
@Test func aToolsEndIsHeardOnlyForToolsKelpActsOn() throws {
    func matches(_ pattern: String, _ tool: String) throws -> Bool {
        try Regex(pattern).firstMatch(in: tool) != nil   // as Claude Code reads one: a regex, unanchored
    }
    func payload(_ event: String, _ tool: String) -> JSONValue {
        .obj([
            "hook_event_name": .string(event), "tool_name": .string(tool), "tool_use_id": "t",
            "tool_input": .obj(["command": "ls", "file_path": "/a"]),
            "tool_response": .string("https://claude.ai/artifact/0f5c4a1e-6a3b-4f3e-9d6e-2b1c1d1e1f10")
        ])
    }
    let tools = [
        "Bash", "Execute", "Edit", "Write", "MultiEdit", "NotebookEdit", "EnterWorktree", "ExitWorktree", "Read",
        "Grep",
        "Glob", "WebFetch", "WebSearch", "Task", "Agent", "TodoWrite", "BashOutput", "AskUserQuestion",
        "mcp__claude-artifacts__publish_version", "mcp__claude-artifacts__read_artifact",
        "mcp__claude_ai_Claude_Docs__create"
    ]
    for tool in tools {
        let post = payload("PostToolUse", tool), failure = payload("PostToolUseFailure", tool)
        let read =
            AgentCommand(hook: post) != nil || SessionHook.edited(of: post) != nil
            || Artifacts.published(hook: post) != nil
        if read { #expect(try matches(Hooks.endsActedOn, tool), "\(tool)'s end is read") }
        if AgentCommand(hook: failure) != nil { #expect(try matches(Hooks.commandTools, tool), "\(tool) failing") }
    }
    #expect(Artifacts.published(hook: payload("PostToolUse", "mcp__claude-artifacts__publish_version")) != nil)
    for tool in ["EnterWorktree", "ExitWorktree"] { #expect(try matches(Hooks.endsActedOn, tool)) }   // its new cwd
    for tool in [
        "Read", "Grep", "Glob", "WebFetch", "Task", "Agent", "BashOutput", "mcp__claude-artifacts__read_artifact"
    ] {
        #expect(try !matches(Hooks.endsActedOn, tool) && !matches(Hooks.commandTools, tool), "\(tool)")
    }
}
