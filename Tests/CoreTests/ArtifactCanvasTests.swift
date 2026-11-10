import Foundation
import Testing

@testable import Core

@Test func aCanvasGroupsItsBoardsIntoRowsInOrder() throws {
    let canvas = try #require(
        ArtifactCanvas.read(
            """
            {"boards": [{"file": "boards/A1.html", "row": "A"}, {"file": "boards/B1.html", "row": "B"},
              {"file": "boards/A2.html", "row": "A", "w": 390, "h": 844}, {"file": "boards/x.html"},
              {"file": "../outside.html"}, {"file": "/etc/passwd"}]}
            """))
    #expect(canvas.rows.map(\.title) == ["A", "B", nil])
    #expect(canvas.rows[0].boards.map(\.file) == ["boards/A1.html", "boards/A2.html"])
    #expect(canvas.boards.count == 4, "a path out of the artifact's folder is no board")
    #expect(ArtifactCanvas.read("{\"boards\": [") == nil)
    #expect(ArtifactCanvas.read(ArtifactCanvas.empty)?.boards == [])
}

@Test func tokensBecomeCSSVariablesPerTheme() {
    let css = DesignSystem.css(
        tokens: """
            {"color": {"bg": {"light": "#fff", "dark": "#111"}, "accent": "#1f7a5a", "bad": "red; } body { x: y"},
             "space": {"4": "16px"}, "font": {"body": "Inter, sans-serif"}, "bad name!": {"x": "1"}}
            """)
    #expect(css.light == "--accent: #1f7a5a; --bg: #fff; --font-body: Inter, sans-serif; --space-4: 16px;")
    #expect(css.dark == "--accent: #1f7a5a; --bg: #111; --font-body: Inter, sans-serif; --space-4: 16px;")
    #expect(DesignSystem.css(tokens: "not json") == ("", ""))
}

@Test func tweaksAreReadAndSetInTheBoard() {
    let board = """
        <!-- tweak --accent: #1f7a5a -->
        <!-- tweak --gap: 12px (8px, 12px, 16px) -->
        <section style="gap: var(--gap)">…</section>
        """
    let tweaks = Tweak.all(in: board)
    #expect(
        tweaks == [
            Tweak(name: "--accent", value: "#1f7a5a", options: []),
            Tweak(name: "--gap", value: "12px", options: ["8px", "12px", "16px"])
        ])
    #expect(tweaks[0].isColor && !tweaks[1].isColor)
    let set = Tweak.set("--gap", to: "16px", in: board)
    #expect(set.map(Tweak.all) == [tweaks[0], Tweak(name: "--gap", value: "16px", options: ["8px", "12px", "16px"])])
    #expect(Tweak.set("--gap", to: "1px; } x", in: board) == nil)
    #expect(Tweak.set("--none", to: "1px", in: board) == nil)
    #expect(Tweak.css(tweaks) == "--accent: #1f7a5a; --gap: 12px;")
}

@Test func theDesignGuideIsShortAndItsPartsAreThere() throws {
    let core = try #require(Artifacts.guide("design", whereTo: "local", system: true))
    #expect(core.contains("kelp artifact new design") && core.contains("kelp artifact check"))
    #expect(core.contains("read DESIGN.md"))
    #expect(core.utf8.count < 4800, "the core stays near 1k tokens: \(core.utf8.count) bytes")
    #expect(try #require(Artifacts.guide("design", whereTo: "local")).contains("guide design system"))
    for part in Artifacts.designParts { #expect(Artifacts.guide("design", whereTo: "local", part: part) != nil) }
    #expect(Artifacts.guide("design", whereTo: "local", part: "nope") == nil)
    #expect(Artifacts.guide("doc", whereTo: "local", part: "system") == nil)
    #expect(Artifacts.Kind.design.file == "canvas.json" && !Artifacts.Kind.design.isHTML)
}
