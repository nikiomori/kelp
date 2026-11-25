import Foundation
import TestSupport
import Testing

@testable import AgentData

@Test func codexMarkupPromptsReachTurnsTitlesAndWorkLogs() throws {
    let at = "2026-11-24T12:00:00.000Z", id = "019f47f3-8f9b-7823-98a3-9195ae68d901"
    func item(_ content: [[String: Any]]) -> [String: Any] {
        ["timestamp": at, "type": "response_item", "payload": ["type": "message", "role": "user", "content": content]]
    }
    func message(_ blocks: String...) -> [String: Any] {
        item(blocks.map { ["type": "input_text", "text": $0] })
    }
    func event(_ text: String) -> [String: Any] {
        [
            "timestamp": at, "type": "event_msg",
            "payload": ["type": "user_message", "message": text, "images": [], "text_elements": []]
        ]
    }
    let root = tmp(), context = "<environment_context>\n<cwd>/work/demo</cwd>\n</environment_context>"
    let notice = "<subagent_notification>\n{\"status\":\"completed\"}\n</subagent_notification>"
    let attachments: [[String: Any]] = [
        ["type": "input_text", "text": #"<image name=[Image #1] path="/work/demo/form.png">"#],
        ["type": "input_image", "image_url": "data:image/png;base64,AA=="],
        ["type": "input_text", "text": "</image>"], ["type": "input_text", "text": "<audio>"],
        ["type": "input_audio", "input_audio": ["data": "AA==", "format": "wav"]],
        ["type": "input_text", "text": "</audio>"]
    ]
    let services = [
        ["timestamp": at, "type": "session_meta", "payload": ["id": id, "cwd": "/work/demo"]],
        message("# AGENTS.md instructions for /work/demo", context), message(notice), event(notice), item(attachments)
    ]
    let html = "<button disabled>Save</button> should be enabled."
    let xml = "<?xml version=\"1.0\"?>\n<feed/>", angle = "< 5 ms is the target."
    let xmlWithContext = context + "\n\n" + xml
    let paired = [
        message(context, html, notice), event(html),
        message(xmlWithContext), event(xmlWithContext),
        message(angle), event(angle)
    ]
    for (lines, title, turns, prompts) in [
        ([], "", [], []),
        ([event(html)], html, [], [html]),
        ([message(context, html)], html, [html], []),
        ([item(attachments + [["type": "input_text", "text": "<audio>"]])], "<audio>", ["<audio>"], []),
        (paired, html, [html, xml, angle], [html, xml, angle])
    ] {
        let url = try write(root, "2026/11/24/rollout-2026-11-24T12-00-00-\(id).jsonl", services + lines)
        #expect(CodexHistory.sessions(root: root).first?.title == title)
        #expect(ConversationTurns.last(in: url).map(\.text) == turns)
        var work = WorkLog()
        work.read(try Data(contentsOf: url))
        #expect(work.prompts.map(\.text) == prompts)
    }
}

@Test func claudeLastPromptTitleSkipsServiceMessages() throws {
    let root = tmp(), notice = "<local-command-stdout>Nothing to clear</local-command-stdout>"
    let service: [Any] = [
        user(notice, "2026-10-18T10:00:00Z"), ["type": "last-prompt", "lastPrompt": notice]
    ]
    let markup = "<title>Dashboard</title>"
    let onlyService = try write(root, "empty.jsonl", service)
    #expect(ClaudeHistory.parse(onlyService)?.title == "")
    let withMarkup = try write(root, "markup.jsonl", service + [["type": "last-prompt", "lastPrompt": markup]])
    #expect(ClaudeHistory.parse(withMarkup)?.title == markup)
}

@Test func generatedPromptTagsMatchWholeNames() {
    for markup in ["<system-reminder-example/>", "<command-line>make</command-line>", "<3", "<div><skill/></div>"] {
        #expect(JSONL.typed(markup) == markup)
    }
    for service in [
        "<system-reminder>one</system-reminder>\n<local-command-stdout>two</local-command-stdout>",
        "<turn_aborted>user interrupted the turn</turn_aborted>", "[Request interrupted by user]",
        "<kelp from=\"reviewer abc12345\" status=\"done\">review</kelp>",
        "<task-notification>done</task-notification>\nRead the output file to retrieve the result: /tmp/log",
        "<command-name>/clear</command-name>\n<command-args></command-args>"
    ] {
        #expect(JSONL.typed(service) == nil)
    }
    #expect(JSONL.typed("<pasted_content id=\"ab12\">\nfix this\n</pasted_content>") == "fix this")
}
