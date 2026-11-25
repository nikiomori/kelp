import Core
import Foundation
import Testing

@testable import Agents

@Test func codexPublicationsUseOnlyThePublishingTools() throws {
    let matcher = try Regex(#require(CodexHooks.events.first { $0.name == "PostToolUse" }?.matcher))
    for tool in Artifacts.codexPublishers.keys {
        #expect(tool.wholeMatch(of: matcher) != nil)
    }
    for tool in [
        "mcp__codex_apps__chatgpt_space_read_page", "mcp__codex_apps__sites_create_site",
        "mcp__codex_apps__sites_save_site_version", "mcp__other__sites_deploy_site_version"
    ] {
        #expect(tool.wholeMatch(of: matcher) == nil)
    }
}

@Test func codexPagesAndSlidesUseTheSpaceLink() throws {
    let pageID = "033fc98b-41ad-4da4-b50b-7fbbb5191129"
    let url = "https://chatgpt.com/space/" + pageID
    let body: JSONValue = .obj([
        "metadata": .obj(["page_id": .string(pageID), "url": .string(url + "?from=chat")]),
        "content": .obj(["page_id": .string(pageID), "title": "A Page"])
    ])
    let page = try #require(
        Artifacts.published(
            hook: codexPublishHook(
                "chatgpt_space_create_page", response: .obj(["structuredContent": body, "content": .array([])]))))
    #expect(page.url == url && page.title == "A Page" && page.type == "doc" && page.page == nil)

    let text = #"{"metadata":{"page_id":"\#(pageID)"}}"#
    let slides = try #require(
        Artifacts.published(
            hook: codexPublishHook(
                "chatgpt_space_create_presentation", response: .array([.obj(["type": "text", "text": .string(text)])])))
    )
    #expect(slides.url == url && slides.title == "From Codex" && slides.type == "slides")

    let unrelated = codexPublishHook(
        "chatgpt_space_create_page", response: .obj(["url": "https://chatgpt.com.example/space/test"]))
    #expect(Artifacts.published(hook: unrelated) == nil)
}

@Test func codexVisualizationsKeepTheParentPageLink() throws {
    let pageID = "033fc98b-41ad-4da4-b50b-7fbbb5191129"
    let input: JSONValue = .obj(["page_id": .string(pageID), "title": "The embed"])
    let result: JSONValue = .obj(["visualization": .obj(["file_id": "file-example"])])
    let tool = "chatgpt_space_create_page_visualization"
    let accepted = codexPublishHook(tool, response: .obj(["structuredContent": result]), input: input)
    let page = try #require(Artifacts.published(hook: accepted))
    #expect(page.url == "https://chatgpt.com/space/" + pageID && page.title == page.url)
    let failed = codexPublishHook(
        tool, response: .obj(["isError": .bool(true), "structuredContent": result]), input: input)
    #expect(Artifacts.published(hook: failed) == nil)
}

@Test func codexSitesAppearAfterSuccessfulDeployment() throws {
    for tool in [
        "sites_deploy_site_version", "sites_deploy_private_site_version",
        "sites_save_version_and_deploy_private", "sites_get_deployment_status"
    ] {
        let url: JSONValue = "https://dashboard.example.org/"
        let live = codexPublishHook(
            tool,
            response: .obj([
                "content": .array([]),
                "structuredContent": .obj(["status": "succeeded", "url": url, "title": "Live dashboard"])
            ]))
        let publication = try #require(Artifacts.published(hook: live))
        #expect(publication.url == url.string && publication.title == "Live dashboard" && publication.type == "page")
        for status: JSONValue in ["pending", "building", "publishing", "failed"] {
            let unfinished = codexPublishHook(tool, response: .obj(["status": status, "url": url]))
            #expect(Artifacts.published(hook: unfinished) == nil)
        }
        let unsafe = codexPublishHook(
            tool, response: .obj(["status": "succeeded", "url": "https://user:password@dashboard.example.org/"]))
        #expect(Artifacts.published(hook: unsafe) == nil)
    }
}

private func codexPublishHook(
    _ tool: String, response: JSONValue, input: JSONValue = .obj(["title": "From Codex"])
) -> JSONValue {
    .obj([
        "hook_event_name": "PostToolUse", "tool_name": .string("mcp__codex_apps__" + tool),
        "tool_input": input, "tool_response": response
    ])
}
