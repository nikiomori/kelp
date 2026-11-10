import Foundation
import Testing

@testable import Core

/// One field takes what people paste from a server's README: a command line, an address, or JSON in any of its wrappings.
@Test func aPastedServerIsRead() throws {
    let line = try #require(ServerEntry.parse("CONTEXT7_API_KEY=abc npx -y @upstash/context7-mcp@latest"))
    #expect(line.name == "context7")
    #expect(
        line.entry
            == ServerEntry(
                command: "npx", args: ["-y", "@upstash/context7-mcp@latest"], env: ["CONTEXT7_API_KEY": "abc"]))
    let address = try #require(ServerEntry.parse(" https://mcp.linear.app/mcp "))
    #expect(address.name == "linear" && address.entry == ServerEntry(url: "https://mcp.linear.app/mcp"))
    let whole = try #require(
        ServerEntry.parse(#"{"mcpServers": {"pg": {"command": "uvx", "args": ["mcp-server-postgres"]}}}"#))
    #expect(whole.name == "pg" && whole.entry.args == ["mcp-server-postgres"])
    let named = try #require(ServerEntry.parse(#"{"figma": {"url": "https://x.dev/mcp", "headers": {"A": "b"}}}"#))
    #expect(named.name == "figma" && named.entry.headers == ["A": "b"])
    let bare = try #require(ServerEntry.parse(#"{"command": "uvx", "args": ["mcp-server-git"]}"#))
    #expect(bare.name == "git")
    #expect(ServerEntry.parse("") == nil && ServerEntry.parse("{}") == nil && ServerEntry.parse(#"{"x": 1}"#) == nil)
    #expect(ServerEntry.parse("node server.js")?.name == "server-js")
}
