import Testing

@testable import Core

/// A page's @keyframes read as keyframes and written back; a new rule goes in the page's first style.
@Test func keyframesReadAndWriteBack() throws {
    let page = """
        <style>h1 { animation: rise 1s }
        @keyframes rise { from { opacity: 0; translate: 0 24px } 45%, 60% { opacity: 1 } to { translate: 0 0 } }
        </style>
        """
    let frames = try #require(CSSKeyframes.frames(page, name: "rise"))
    #expect(frames.map(\.at) == [0, 45, 60, 100])
    #expect(frames[0].value("translate") == "0 24px" && frames[1].value("opacity") == "1")
    var changed = frames
    changed[1].set("animation-timing-function", "ease-in-out")
    changed.remove(at: 2)
    changed.append(.init(at: 80, declarations: [.init(property: "opacity", value: "0.5")]))
    let written = try #require(CSSKeyframes.write(page, name: "rise", frames: changed))
    #expect(written.contains("45% { opacity: 1; animation-timing-function: ease-in-out }\n  80% { opacity: 0.5 }"))
    #expect(CSSKeyframes.frames(written, name: "rise")?.map(\.at) == [0, 45, 80, 100])
    #expect(CSSKeyframes.frames(page, name: "ris") == nil)
    let added = try #require(CSSKeyframes.add(page, name: "t-motion", frames: [.init(at: 0, declarations: [])]))
    #expect(CSSKeyframes.frames(added, name: "t-motion")?.count == 1)
    #expect(CSSKeyframes.add(page, name: "rise", frames: []) == nil)
    // A comment before a keyframe doesn't lose it; a place that doesn't read leaves the rule alone.
    let noted = "<style>@keyframes up { /* from below */ from { opacity: 0 } to { opacity: 1 } }</style>"
    #expect(CSSKeyframes.frames(noted, name: "up")?.map(\.at) == [0, 100])
    #expect(
        CSSKeyframes.frames("<style>@keyframes up { entry 10% { opacity: 0 } to { opacity: 1 } }</style>", name: "up")
            == nil)
}
