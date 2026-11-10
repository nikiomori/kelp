import Core
import Foundation
import Testing

@testable import BuiltinFiles

/// A project with a design system and a canvas of two boards, one of them missing, in a temporary folder.
private func demo() throws -> (root: URL, folder: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-\(UUID().uuidString)")
    let folder = root.appendingPathComponent(".kelp/artifacts/home")
    let system = DesignSystem.dir(root: root.path)
    try FileManager.default.createDirectory(
        at: folder.appendingPathComponent("boards"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
    try ##"{"color": {"bg": {"light": "#fafafa", "dark": "#111111"}, "accent": "#1f7a5a"}}"##
        .write(to: system.appendingPathComponent("tokens.json"), atomically: true, encoding: .utf8)
    try ".button { color: var(--accent); }".write(
        to: system.appendingPathComponent("kit.css"), atomically: true, encoding: .utf8)
    try "<!-- tweak --gap: 8px (8px, 16px) -->\n<h1 data-id=\"t\" style=\"color: #333\">Hi & \"you\"</h1>".write(
        to: folder.appendingPathComponent("boards/A.html"), atomically: true, encoding: .utf8)
    return (root, folder)
}

@Test func aCanvasPageDrawsEachBoardInLightAndDarkFromTheSystem() throws {
    let (root, folder) = try demo()
    defer { try? FileManager.default.removeItem(at: root) }
    let json =
        #"{"boards": [{"file": "boards/A.html", "row": "A. One", "w": 390, "h": 844}, {"file": "boards/B.html"}]}"#
    let page = CanvasPage.build(json, folder: folder, root: root.path, themes: .both, ground: nil)
    #expect(page.html.components(separatedBy: "<iframe").count - 1 == 2, "A in light and dark; B is missing")
    #expect(page.html.contains("data-theme=\"dark\"") && page.html.contains("--bg: #111111;"))
    #expect(page.html.contains("--gap: 8px;"), "the board's tweaks are set on its page")
    #expect(page.html.contains("&lt;h1 data-id=&quot;t&quot;"), "the fragment is escaped into srcdoc")
    #expect(page.html.contains("<h2>A. One</h2>") && page.html.contains("390 × 844"))
    #expect(page.issues.contains("boards/B.html: no such file"))
    #expect(page.issues.contains("boards/A.html: 1 colours typed in; use the tokens (var(--name))"))
    let light = CanvasPage.build(json, folder: folder, root: root.path, themes: .light, ground: nil)
    #expect(light.html.components(separatedBy: "<iframe").count - 1 == 1)
}

@Test func aCanvasThatDoesntReadSaysSo() throws {
    let (root, folder) = try demo()
    defer { try? FileManager.default.removeItem(at: root) }
    let page = CanvasPage.build("{", folder: folder, root: root.path, themes: .both, ground: nil)
    #expect(page.issues.first?.hasPrefix("canvas.json doesn't read") == true)
    #expect(CanvasPage.lint("<html><body><script>x()</script>", board: "b", hasSystem: false).count == 2)
}
