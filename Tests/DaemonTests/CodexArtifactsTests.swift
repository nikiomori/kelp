import Core
import Foundation
import Testing

@testable import Daemon

@Test func codexRemotePublicationsJoinCallsAndResults() throws {
    let tail = #"""
        {"type":"response_item","payload":{"type":"function_call","call_id":"read","name":"mcp__codex_apps__chatgpt_space_read_page"}}
        {"type":"response_item","payload":{"type":"function_call","call_id":"made","name":"chatgpt_space_create_presentation","namespace":"mcp__codex_apps","arguments":"{\"title\":\"Deck\"}"}}
        {"timestamp":"2026-11-25T12:00:30.123Z","type":"response_item","payload":{"type":"function_call_output","call_id":"read","output":"{\"page_id\":\"old\"}"}}
        {"timestamp":"2026-11-25T12:00:30.456Z","type":"response_item","payload":{"type":"function_call_output","call_id":"made","output":"Wall time: 0.0142 seconds\n Output:\n{\"metadata\":{\"page_id\":\"new-deck\"}}"}}
        """#
    let found = Artifacts.codexPublications(inTranscript: Data(tail.utf8))
    #expect(found.count == 1)
    let page = try #require(found.first)
    #expect(page.title == "Deck" && page.type == "slides" && page.url == "https://chatgpt.com/space/new-deck")
    #expect(page.at != nil)
}
