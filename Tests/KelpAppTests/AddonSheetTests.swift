import AppKit
import Core
import Foundation
import Testing

@testable import BuiltinAgents

@MainActor
@Suite struct AddonSheetTests {
    /// What's pasted is told apart: a skill's folder, a repository of skills, a server by its command, address or JSON.
    @Test func aPasteIsASkillOrAServer() {
        #expect(AddonPaste.read("~/skills/notes") == .folder("~/skills/notes"))
        #expect(AddonPaste.read("https://github.com/acme/skills") == .repository("https://github.com/acme/skills"))
        #expect(AddonPaste.read("git@host:me/skills.git") == .repository("git@host:me/skills.git"))
        #expect(AddonPaste.read("https://mcp.linear.app/mcp")?.isServer == true)
        #expect(AddonPaste.read("npx -y @upstash/context7-mcp")?.isServer == true)
        #expect(AddonPaste.read("  ") == nil && AddonPaste.read("{}") == nil)
    }

    /// The sheet says what it read under the field, takes a name and what the server signs in with, and stays its
    /// width; with KELP_SHOT it writes its picture there, for a look by eye.
    @Test func theSheetShowsWhatItRead() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let found = [
            Addon(
                kind: .server, name: "node_repl", source: .yours, origin: "~/.codex/config.toml", agents: ["codex"],
                key: "server:node_repl"),
            Addon(
                kind: .skill, name: "taste-skill", source: .yours, agents: ["claude", "cursor"],
                key: "skill:taste-skill")
        ]
        let sheet = AddonSheet(app: rig.app, worktreeId: rig.workspace.id, project: "Kelp", items: found)
        func all(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + all($0) } }
        func texts() -> [String] {
            all(sheet.window.contentView ?? NSView()).compactMap { ($0 as? NSTextField)?.stringValue }
        }
        func shot(_ name: String) {
            guard let dir = ProcessInfo.processInfo.environment["KELP_SHOT"], let view = sheet.window.contentView
            else { return }
            sheet.window.appearance = NSAppearance(named: .aqua)
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            let picture = NSImage(size: view.bounds.size)
            picture.lockFocus()
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
            rep.draw(in: view.bounds)
            picture.unlockFocus()
            let png = picture.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
                .representation(using: .png, properties: [:])
            try? png?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
        #expect(texts().contains("Found on This Mac") && texts().contains("node_repl"))
        #expect(!texts().contains("MCP Server"))
        let empty = sheet.window.frame.height
        shot("empty")

        sheet.field.stringValue = "CONTEXT7_API_KEY=abc npx -y @upstash/context7-mcp"
        sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: sheet.field))
        #expect(texts().contains("MCP Server") && texts().contains("CONTEXT7_API_KEY") && texts().contains("Gets it"))
        #expect(sheet.name.stringValue == "context7" && sheet.secrets["env:CONTEXT7_API_KEY"]?.stringValue == "abc")
        #expect(sheet.window.frame.height > empty && sheet.window.frame.width == 480)
        shot("server")

        sheet.field.stringValue = "https://github.com/acme/skills"
        sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: sheet.field))
        #expect(texts().contains("Skills from a Repository") && !texts().contains("Can’t get it"))
        #expect(sheet.secrets.isEmpty)
        shot("repository")
    }
}
