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
    let motion = try #require(Artifacts.guide("motion", whereTo: "agent"))
    #expect(motion.contains("stay in the project") && motion.contains("data-duration") && motion.contains("data-start"))
    for kind in ["design", "doc", "slides"] {
        #expect(try #require(Artifacts.guide(kind, whereTo: "local")).contains("kelp artifact reply <name> <#>"))
    }
    #expect(core.utf8.count < 4800, "the core stays near 1k tokens: \(core.utf8.count) bytes")
    #expect(try #require(Artifacts.guide("design", whereTo: "local")).contains("guide design system"))
    for part in Artifacts.designParts { #expect(Artifacts.guide("design", whereTo: "local", part: part) != nil) }
    #expect(Artifacts.guide("design", whereTo: "local", part: "nope") == nil)
    #expect(Artifacts.guide("doc", whereTo: "local", part: "system") == nil)
    let dashboard = try #require(Artifacts.guide("dashboard", whereTo: "local", system: true))
    #expect(dashboard.contains("kelp artifact new dashboard") && dashboard.contains("data-source"))
    #expect(try #require(Artifacts.guide("slides", whereTo: "local")).contains("guide design deck"))
}

/// A canvas is a deck when every board is a 16:9 frame; a screen as tall as its content or a phone isn't a slide.
@Test(
    arguments: [
        ([(1920, 1080), (1280, 720)], true),
        ([(1920, 1080), (390, 844)], false),
        ([(1920, nil)], false),
        ([], false)
    ] as [([(Int, Int?)], Bool)])
func aCanvasIsADeckWhenEveryBoardIsASlide(sizes: [(Int, Int?)], deck: Bool) {
    let boards = sizes.enumerated().map {
        ArtifactCanvas.Board(file: "boards/\($0.offset).html", w: $0.element.0, h: $0.element.1)
    }
    #expect(ArtifactCanvas(boards: boards).isDeck == deck)
}
