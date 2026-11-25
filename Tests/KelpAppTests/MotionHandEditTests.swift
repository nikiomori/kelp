import AppKit
import Core
import DesignKit
import Foundation
import ImageIO
import TestSupport
import Testing

@testable import BuiltinFiles
@testable import EditorKit
@testable import KelpKit

extension OneAtATime {
    /// An element moved by hand on a motion page comes back with ⌘Z and goes again with ⇧⌘Z; a second ⌘Z with
    /// nothing left changes nothing.
    @Test func aHandEditOnAMotionPageIsTakenBackAndBroughtAgain() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-motion-undo/.kelp/artifacts/launch/motion.html")
        let page = #"<body data-width="1920" data-height="1080"><h1 data-id="title">Hi</h1></body>"#
        let editor = CodeEditor(text: page, url: url)
        let tab = MarkdownTab(editor: editor, url: url, app: AppModel())
        _ = tab.canvasMessage(
            "style", ["board": "motion.html", "id": "title", "property": "translate", "value": "10px 20px"])
        let moved = editor.text
        #expect(moved.contains(#"style="translate: 10px 20px""#))
        tab.undoHandEdit(redo: false)
        #expect(try await waitFor(5) { editor.text == page })
        tab.undoHandEdit(redo: true)
        #expect(try await waitFor(5) { editor.text == moved })
        tab.undoHandEdit(redo: false)
        #expect(try await waitFor(5) { editor.text == page })
        tab.undoHandEdit(redo: false)
        #expect(editor.text == page)
    }
}

extension OneAtATime {
    /// A corner dragged sizes an element by several properties at once; they are one hand edit, and one ⌘Z.
    @Test func aDragThatSizesAnElementIsOneStep() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-motion-undo/.kelp/artifacts/launch/motion.html")
        let page = #"<body data-width="1920" data-height="1080"><div data-id="box">Hi</div></body>"#
        let editor = CodeEditor(text: page, url: url)
        let tab = MarkdownTab(editor: editor, url: url, app: AppModel())
        _ = tab.canvasMessage(
            "styles",
            ["board": "motion.html", "id": "box", "props": ["width": "120px", "translate": "4px 8px"]])
        #expect(editor.text.contains("width: 120px") && editor.text.contains("translate: 4px 8px"))
        #expect(tab.handSteps.undo.count == 1)
        tab.undoHandEdit(redo: false)
        #expect(try await waitFor(5) { editor.text == page })
    }
}

extension OneAtATime {
    /// A scene copied comes right after itself in time, and the scenes after it move later by its length; an element
    /// taken out is gone from the page.
    @Test func aSceneCopiedComesAfterItselfAndPushesTheRest() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-motion-undo/.kelp/artifacts/launch/motion.html")
        let page = """
            <body data-width="1920" data-height="1080">
            <section data-id="a" data-start="0" data-duration="2"><h1 data-id="t">Hi</h1></section>
            <section data-id="b" data-start="2" data-duration="3"></section>
            </body>
            """
        let editor = CodeEditor(text: page, url: url)
        let tab = MarkdownTab(editor: editor, url: url, app: AppModel())
        tab.motionMessage([
            "t": 0, "duration": 5,
            "scenes": [
                ["id": "a", "title": "A", "start": 0, "duration": 2],
                ["id": "b", "title": "B", "start": 2, "duration": 3]
            ]
        ])
        _ = tab.canvasMessage("duplicate", ["board": "motion.html", "id": "a"])
        #expect(editor.text.contains(#"data-id="a-2" data-start="2" data-duration="2""#))
        #expect(editor.text.contains(#"data-id="t-2""#))
        #expect(editor.text.contains(#"data-id="b" data-start="4""#))
        _ = tab.canvasMessage("remove", ["board": "motion.html", "id": "t"])
        #expect(!editor.text.contains(#"data-id="t""#) && editor.text.contains(#"data-id="t-2""#))
    }
}

extension OneAtATime {
    /// Lanes restacked on the timeline set each element's z-index as one edit; an element hidden by its eye gets
    /// data-hidden, and loses it when shown again.
    @Test func layersRestackAndHideOnThePage() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-motion-undo/.kelp/artifacts/launch/motion.html")
        let page = #"<body data-width="1920" data-height="1080"><p data-id="a">A</p><p data-id="b">B</p></body>"#
        let editor = CodeEditor(text: page, url: url)
        let tab = MarkdownTab(editor: editor, url: url, app: AppModel())
        _ = tab.canvasMessage(
            "restyle",
            [
                "board": "motion.html",
                "changes": [
                    ["id": "b", "props": ["z-index": "2", "position": "relative"]],
                    ["id": "a", "props": ["z-index": "1"]]
                ]
            ])
        #expect(editor.text.contains(#"data-id="b" style="position: relative; z-index: 2""#))
        #expect(editor.text.contains(#"data-id="a" style="z-index: 1""#))
        #expect(tab.handSteps.undo.count == 1)
        tab.hideElement("a", true)
        #expect(editor.text.contains(#"data-hidden="true""#))
        tab.hideElement("a", false)
        #expect(!editor.text.contains("data-hidden"))
        tab.lockElement("a", true)
        #expect(editor.text.contains(#"data-locked="true""#))
        tab.lockElement("a", false)
        #expect(!editor.text.contains("data-locked"))
    }
}

extension OneAtATime {
    /// A shape chosen for the stage sets the body's size, as a hand edit ⌘Z takes back.
    @Test func aStageTakesAnotherShape() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-motion-undo/.kelp/artifacts/launch/motion.html")
        let page = #"<html><body data-width="1920" data-height="1080"><p data-id="a">A</p></body></html>"#
        let editor = CodeEditor(text: page, url: url)
        let tab = MarkdownTab(editor: editor, url: url, app: AppModel())
        tab.resizeStage(1080, 1920)
        #expect(editor.text.contains(#"<body data-width="1080" data-height="1920">"#))
        tab.undoHandEdit(redo: false)
        #expect(try await waitFor(5) { editor.text == page })
    }
}

/// A GIF loops at 30 frames a second at most, and holds each frame it was given.
@Test func aGIFHoldsEachFrameAtThirtyAtMost() throws {
    #expect(MotionExport(format: .gif, fps: 60).rate == 30)
    #expect(MotionExport(format: .mp4, fps: 60).rate == 60)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("motion-\(UUID().uuidString).gif")
    defer { try? FileManager.default.removeItem(at: url) }
    let gif = try MotionGIF(url, frames: 2, fps: 24)
    let context = try #require(
        CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let frame = try #require(context.makeImage())
    gif.add(frame)
    gif.add(frame)
    try gif.finish()
    let read = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    #expect(CGImageSourceGetCount(read) == 2)
}

extension OneAtATime {
    /// An element chosen without a data-id gets one written into the page, and is chosen as it.
    @Test func anElementChosenWithoutAnIDGetsOne() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-motion-undo/.kelp/artifacts/launch/motion.html")
        let page = #"<html><body data-width="1920" data-height="1080"><p>A</p><p>B</p></body></html>"#
        let editor = CodeEditor(text: page, url: url)
        let tab = MarkdownTab(editor: editor, url: url, app: AppModel())
        _ = tab.canvasMessage("giveID", ["board": "motion.html", "tag": "p", "index": 1])
        #expect(editor.text.contains(#"<p>A</p><p data-id="p-1">B</p>"#))
        #expect(tab.chosen?.id == "p-1")
    }
}

/// A double click on the line over the motion studio folds it to its row of controls, and another opens it again.
@MainActor @Test func aDoubleClickFoldsTheMotionStudio() throws {
    _ = NSApplication.shared
    let studio = NSView(), stage = NSView()
    let split = MotionSplit(stage: stage, studio: studio)
    split.autosaveName = nil
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
    window.contentView = split
    split.setPosition(350, ofDividerAt: 0)
    split.layoutSubtreeIfNeeded()
    let open = studio.frame.height
    func doubleClick() throws {
        let y = studio.frame.minY - split.dividerThickness / 2
        let event = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: split.convert(NSPoint(x: 300, y: y), to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2,
                pressure: 1))
        split.mouseDown(with: event)
        split.layoutSubtreeIfNeeded()
    }
    try doubleClick()
    #expect(studio.frame.height < 40)
    try doubleClick()
    #expect(abs(studio.frame.height - open) < 2)
}

/// VoiceOver reads the timeline's clips and marks by name and time.
@MainActor @Test func theTimelineReadsToVoiceOver() {
    let timeline = MotionTimeline(frame: NSRect(x: 0, y: 0, width: 600, height: 220))
    timeline.set(
        at: 0, length: 5, scenes: [.init(id: "a", title: "Intro", start: 0, length: 2)],
        tracks: [.init(id: "t", title: "Title", start: 1, length: 1, hidden: true)],
        marks: [.init(id: 3, time: 2.5, yours: true)])
    let labels = (timeline.accessibilityChildren() as? [NSAccessibilityElement])?.compactMap { $0.accessibilityLabel() }
    #expect(
        labels == [
            "Intro, scene, 0.0 to 2.0 seconds", "Title, hidden, 1.0 to 2.0 seconds", "Mark 3, at 2.5 seconds"
        ])
}

/// A page's commands (play, export, an element's) can't be chosen while no agent's page is in front.
@MainActor @Test func aPagesCommandsWaitForThePage() {
    let commands = Builtins.artifactPageCommands(AppModel())
    #expect(commands.count == 8)
    #expect(commands.allSatisfy { $0.enabled?() == false })
}

extension OneAtATime {
    /// The Time row of Edit's column moves a scene by its own times, and an element by its animation's.
    @Test func theTimeRowMovesAnElementInTime() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-motion-undo/.kelp/artifacts/launch/motion.html")
        let page = """
            <body data-width="1920" data-height="1080">
            <section data-id="a" data-start="0" data-duration="2"><h1 data-id="t">Hi</h1></section>
            </body>
            """
        let editor = CodeEditor(text: page, url: url)
        let tab = MarkdownTab(editor: editor, url: url, app: AppModel())
        tab.motionMessage([
            "t": 0, "duration": 2, "scenes": [["id": "a", "title": "A", "start": 0, "duration": 2]],
            "tracks": [["id": "t", "title": "T", "start": 0, "end": 1, "delays": [0], "lengths": [1]]]
        ])
        _ = tab.canvasMessage("retimeElement", ["id": "a", "start": 0.5, "length": 3])
        #expect(editor.text.contains(#"data-id="a" data-start="0.5" data-duration="3""#))
        _ = tab.canvasMessage("retimeElement", ["id": "t", "start": 0.2, "length": 0.6])
        #expect(editor.text.contains("animation-delay: 0.2s; animation-duration: 0.6s"))
    }
}

extension OneAtATime {
    /// S splits a scene at the time shown into two that meet there; ⇥ trims a scene's end to the time; a clip copied
    /// pastes at the time shown with new ids.
    @Test func aSceneSplitsTrimsAndPastesAtTheTime() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-motion-undo/.kelp/artifacts/launch/motion.html")
        let page = """
            <body data-width="1920" data-height="1080">
            <section data-id="a" data-start="0" data-duration="2"><h1 data-id="t">Hi</h1></section>
            </body>
            """
        let editor = CodeEditor(text: page, url: url)
        let tab = MarkdownTab(editor: editor, url: url, app: AppModel())
        tab.motionMessage(["t": 0.5, "duration": 2, "scenes": [["id": "a", "title": "A", "start": 0, "duration": 2]]])
        tab.splitClip(nil)
        #expect(editor.text.contains(#"data-id="a" data-start="0" data-duration="0.5""#))
        #expect(editor.text.contains(#"data-id="a-2" data-start="0.5" data-duration="1.5""#))
        tab.motionMessage([
            "t": 1.5, "duration": 2,
            "scenes": [
                ["id": "a", "title": "A", "start": 0, "duration": 0.5],
                ["id": "a-2", "title": "A", "start": 0.5, "duration": 1.5]
            ]
        ])
        tab.trimClip("a-2", end: true)
        #expect(editor.text.contains(#"data-id="a-2" data-start="0.5" data-duration="1""#))
        tab.copyClip("a", cut: false)
        tab.pasteClip()
        #expect(editor.text.contains(#"data-id="a-3" data-start="1.5" data-duration="0.5""#))
    }
}

/// A box dragged over the timeline's empty room takes in the clips it touches; ⇧-click takes one away.
@MainActor @Test func aBoxOnTheTimelineTakesTheClipsItTouches() throws {
    _ = NSApplication.shared
    let timeline = MotionTimeline(frame: NSRect(x: 0, y: 0, width: 600, height: 220))
    let window = NSWindow(contentRect: timeline.frame, styleMask: [.titled], backing: .buffered, defer: true)
    window.contentView = timeline
    timeline.set(
        at: 0, length: 6,
        scenes: [.init(id: "a", title: "A", start: 0, length: 2), .init(id: "b", title: "B", start: 2, length: 4)],
        tracks: [.init(id: "t", title: "T", start: 4, length: 1, delays: [4], lengths: [1])])
    func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, shift: Bool = false) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: timeline.convert(NSPoint(x: x, y: y), to: nil),
                modifierFlags: shift ? .shift : [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
    }
    // From the empty room of the element lane's start to past both scenes' middle, up through the scenes' lane.
    timeline.mouseDown(with: try mouse(.leftMouseDown, 200, 60))
    timeline.mouseDragged(with: try mouse(.leftMouseDragged, 560, 26))
    timeline.mouseUp(with: try mouse(.leftMouseUp, 560, 26))
    #expect(timeline.selecting.ids.isSuperset(of: ["b", "t"]))
    timeline.mouseDown(with: try mouse(.leftMouseDown, 520, 34, shift: true))   // ⇧ on B takes it away
    #expect(!timeline.selecting.ids.contains("b"))
}

extension OneAtATime {
    /// Edits that one change made (All like this, on several boards) are one ⌘Z, taken back last first.
    @Test func oneChangeOnSeveralFilesIsOneUndo() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-motion-undo/.kelp/artifacts/like/motion.html")
        let editor = CodeEditor(text: "<p>0</p>", url: url)
        let tab = MarkdownTab(editor: editor, url: url, app: AppModel())
        let by = UUID()
        for (was, now) in [("<p>0</p>", "<p>1</p>"), ("<p>1</p>", "<p>2</p>")] {
            editor.apply(text: now, selection: NSRange(location: 0, length: 0))
            tab.didHandEdit(
                HandEdit(board: "motion.html", id: ".p", what: "color", from: nil, to: "red"), path: url.path,
                before: was, after: now, by: by)
        }
        #expect(tab.handSteps.undo.count == 1)
        tab.undoHandEdit(redo: false)
        #expect(try await waitFor(5) { editor.text == "<p>0</p>" })
        tab.undoHandEdit(redo: true)
        #expect(try await waitFor(5) { editor.text == "<p>2</p>" })
    }

    /// Clips moved together are one edit and one ⌘Z; two clips copied paste at the time keeping their distance.
    @Test func clipsMovedOrPastedTogetherAreOneEdit() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-motion-undo/.kelp/artifacts/launch/motion.html")
        let page = """
            <body data-width="1920" data-height="1080">
            <section data-id="a" data-start="0" data-duration="1"></section>
            <section data-id="b" data-start="1" data-duration="1"></section>
            </body>
            """
        let editor = CodeEditor(text: page, url: url)
        let tab = MarkdownTab(editor: editor, url: url, app: AppModel())
        let a = MotionTimeline.Clip(id: "a", title: "A", start: 0, length: 1)
        let b = MotionTimeline.Clip(id: "b", title: "B", start: 1, length: 1)
        var a2 = a, b2 = b
        a2.start = 0.5
        b2.start = 1.5
        tab.retimeAll([(a, a2), (b, b2)])
        #expect(
            editor.text.contains(#"data-id="a" data-start="0.5""#)
                && editor.text.contains(#"data-id="b" data-start="1.5""#))
        #expect(tab.handSteps.undo.count == 1)
        tab.undoHandEdit(redo: false)
        #expect(try await waitFor(5) { editor.text == page })
        tab.motionMessage([
            "t": 3, "duration": 5,
            "scenes": [
                ["id": "a", "title": "A", "start": 0, "duration": 1],
                ["id": "b", "title": "B", "start": 1, "duration": 1]
            ]
        ])
        tab.copyClips(["a", "b"], cut: false)
        tab.pasteClip()
        #expect(
            editor.text.contains(#"data-id="a-2" data-start="3""#)
                && editor.text.contains(#"data-id="b-2" data-start="4""#))
    }
}

extension OneAtATime {
    /// A keyframe dragged on its lane moves in the page's @keyframes; its menu's easing goes on it; the element dragged
    /// on the stage at a time between keyframes makes one there with its place.
    @Test func keyframesChangeThePagesRule() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-motion-undo/.kelp/artifacts/launch/motion.html")
        let page = """
            <html><head><style>h1 { animation: rise 2s 1s both }
            @keyframes rise { 0% { opacity: 0 } 50% { opacity: 1 } 100% { translate: 0 0 } }
            </style></head><body data-width="1920" data-height="1080"><h1 data-id="t">Hi</h1></body></html>
            """
        let editor = CodeEditor(text: page, url: url)
        let tab = MarkdownTab(editor: editor, url: url, app: AppModel())
        tab.motionMessage([
            "t": 1.5, "duration": 3,
            "tracks": [
                [
                    "id": "t", "title": "T", "start": 1, "end": 3, "delays": [1], "lengths": [2],
                    "keys": [
                        "name": "rise", "delay": 1, "duration": 2, "at": [0, 50, 100],
                        "easing": ["linear", "linear", "linear"]
                    ]
                ]
            ]
        ])
        tab.moveKeyframe("t", from: 50, to: 40)
        #expect(editor.text.contains("40% { opacity: 1 }"))
        tab.motionMessage([
            "t": 1.5, "duration": 3,
            "tracks": [
                [
                    "id": "t", "title": "T", "start": 1, "end": 3, "delays": [1], "lengths": [2],
                    "keys": [
                        "name": "rise", "delay": 1, "duration": 2, "at": [0, 40, 100],
                        "easing": ["linear", "linear", "linear"]
                    ]
                ]
            ]
        ])
        tab.easeKeyframe("t", at: 40, "ease-in-out")
        #expect(editor.text.contains("40% { opacity: 1; animation-timing-function: ease-in-out }"))
        tab.keyframeTranslate("t", "10px 0px")   // at 1.5 s: 25% of the animation, where there's no keyframe yet
        #expect(editor.text.contains("25% { translate: 10px 0px }"))
    }
}

extension OneAtATime {
    /// A mark on an element with no data-id (`img@1`) gets one written into the page before it's kept, and points at
    /// it; marked again, the same id is found, not a second one.
    @Test func aMarkedElementGetsAnID() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-motion-undo/.kelp/artifacts/launch/motion.html")
        let page = #"<html><body data-width="1920" data-height="1080"><img src="a.png"><img src="b.png"></body></html>"#
        let editor = CodeEditor(text: page, url: url)
        let tab = MarkdownTab(editor: editor, url: url, app: AppModel())
        let mark = ArtifactMark(kind: .element, board: "motion.html", target: "img@1")
        let first = await tab.stampIDs([mark])
        #expect(first.first?.target == "[data-id=img-1]")
        #expect(editor.text.contains(#"<img data-id="img-1" src="b.png">"#))
        let again = await tab.stampIDs([mark])
        #expect(again.first?.target == "[data-id=img-1]" && editor.text.components(separatedBy: "data-id").count == 2)
    }
}

extension OneAtATime {
    /// An exit's length changed in Edit is written on the element and in the page's style, ending with its scene.
    @Test func anExitEndsWithItsScene() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-motion-undo/.kelp/artifacts/launch/motion.html")
        let page =
            #"<html><head></head><body data-width="1920" data-height="1080"><h1 data-id="t">Hi</h1></body></html>"#
        let editor = CodeEditor(text: page, url: url)
        let tab = MarkdownTab(editor: editor, url: url, app: AppModel())
        #expect(
            tab.presetsMessage(
                "animLength",
                ["id": "t", "which": "out", "now": "fade-out 0.4 ease-in 1.6", "length": 0.5, "start": 0, "end": 2]))
        #expect(editor.text.contains(#"data-kelp-out="fade-out 0.5 ease-in 1.5""#))
        #expect(editor.text.contains("kelp-fade-out 0.5s ease-in 1.5s both"))
    }
}

extension OneAtATime {
    /// A crossfade at a seam starts the next scene earlier by its length and fades the two over each other; taking it
    /// away puts the scene back where it began.
    @Test func aSeamGetsACrossfade() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-motion-undo/.kelp/artifacts/launch/motion.html")
        let page = """
            <html><head></head><body data-width="1920" data-height="1080">
            <div data-id="a" data-start="0" data-duration="2">A</div><div data-id="b" data-start="2" data-duration="2">B</div>
            </body></html>
            """
        let editor = CodeEditor(text: page, url: url)
        let tab = MarkdownTab(editor: editor, url: url, app: AppModel())
        let scenes: [[String: Any]] = [
            ["id": "a", "title": "A", "start": 0, "duration": 2], ["id": "b", "title": "B", "start": 2, "duration": 2]
        ]
        tab.motionMessage(["t": 0, "duration": 4, "scenes": scenes])
        let menu = try #require(tab.seamMenu("a", "b"))
        menu.performActionForItem(at: 1)   // Crossfade
        #expect(editor.text.contains(#"data-id="b" data-start="1.6" data-duration="2.4""#))
        #expect(
            editor.text.contains("kelp-fade 0.4s ease-in-out 1.6s both")
                && editor.text.contains("kelp-fade-out 0.4s ease-in-out 1.6s both"))
        tab.motionMessage([
            "t": 0, "duration": 4,
            "scenes": [scenes[0], ["id": "b", "title": "B", "start": 1.6, "duration": 2.4, "trans": "fade"]]
        ])
        let again = try #require(tab.seamMenu("a", "b"))
        again.performActionForItem(at: again.numberOfItems - 1)   // Remove Transition
        #expect(
            editor.text.contains(#"data-id="b" data-start="2" data-duration="2""#)
                && !editor.text.contains("kelp-motion"))
    }
}

/// Closing the empty stretches between scenes moves what starts after each left by the stretches before it; what
/// starts before stays.
@MainActor @Test func closingAGapMovesWhatComesAfter() {
    typealias Clip = MotionTimeline.Clip
    let scenes = [
        Clip(id: "a", title: "A", start: 0, length: 2), Clip(id: "b", title: "B", start: 3, length: 1),
        Clip(id: "c", title: "C", start: 5, length: 1)
    ]
    let gaps = MotionTimeline.gaps(in: scenes)
    #expect(gaps == [2...3, 4...5])
    let title = Clip(id: "t", title: "Title", start: 1.5, length: 1),
        logo = Clip(id: "l", title: "Logo", start: 5.2, length: 1)
    let moved = MotionTimeline.closing(gaps, scenes + [title, logo]).map { "\($0.now.id) \($0.now.start)" }
    #expect(moved == ["b 2.0", "c 3.0", "l 3.2"])
    #expect(MotionTimeline.closing([gaps[0]], scenes).map(\.now.start) == [2, 4])
}

extension OneAtATime {
    /// `kelp artifact check` on a motion page waits for the window's next drawing of it, as on a design.
    @Test func aMotionPageTakesAWaitingCheck() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-motion-check/.kelp/artifacts/launch/motion.html")
        let app = AppModel()
        let path = Paths.real(url.path) ?? url.path
        app.latest(ArtifactCheckEvent.self).byKey[path] = ArtifactCheckEvent(request: "r1", path: path)
        let tab = MarkdownTab(
            editor: CodeEditor(text: #"<body data-width="1920" data-height="1080"></body>"#, url: url), url: url,
            app: app)
        _ = tab.view
        #expect(tab.pendingCheck == "r1")
    }
}

extension OneAtATime {
    /// A dashboard's View menu has the languages a design has, but no themes: it follows the window's look.
    @Test func aDashboardsViewMenuHasNoThemes() {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-dash-view/.kelp/artifacts/numbers/canvas.json")
        let tab = MarkdownTab(editor: CodeEditor(text: #"{"boards": []}"#, url: url), url: url, app: AppModel())
        let titles = { tab.viewMenu().items.map(\.title) }
        #expect(titles().contains("Light"))
        tab.isDashboard = true
        #expect(titles().contains("+40%") && !titles().contains("Light"))
    }
}

extension OneAtATime {
    /// A dashboard with sources offers how often it updates while open, and keeps the choice; a dashboard without
    /// sources (its agent updates it) and a design offer nothing.
    @Test func aDashboardWithSourcesChoosesHowOftenItUpdates() {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-dash-every/.kelp/artifacts/numbers/canvas.json")
        let json = #"{"boards": [], "sources": {"issues": {"run": "gh issue list --json number", "map": "length"}}}"#
        let tab = MarkdownTab(editor: CodeEditor(text: json, url: url), url: url, app: AppModel())
        #expect(tab.updateMenu() == nil, "a design")
        tab.isDashboard = true
        let menu = tab.updateMenu()
        #expect(menu?.items.map(\.title) == ["When Opened", "Every 15 Minutes", "Every Hour"])
        #expect(menu?.items.first?.state == .on)
        tab.updateEvery = 60
        #expect(tab.updateMenu()?.items.last?.state == .on)
        tab.updateEvery = nil
        let bare = MarkdownTab(editor: CodeEditor(text: #"{"boards": []}"#, url: url), url: url, app: AppModel())
        bare.isDashboard = true
        #expect(bare.updateMenu() == nil)
    }
}

extension OneAtATime {
    /// A CSV shown as a table: a cell changed changes the file's text, a row added and deleted too; a column's head
    /// sorts what's shown, numbers as numbers, and leaves the file as it is.
    @Test func aCSVIsChangedAsATable() throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-csv-grid/sales.csv")
        let editor = CodeEditor(text: "name,sold\nB,10\nA,9\n", url: url)
        let grid = CSVGrid(editor: editor)
        let table = try #require(
            grid.view.subviews.first.flatMap { ($0 as? NSScrollView)?.documentView as? NSTableView })
        #expect(table.numberOfRows == 2 && table.tableColumns.map(\.title) == ["name", "sold"])
        grid.tableView(table, setObjectValue: "11", for: table.tableColumns[1], row: 0)
        #expect(editor.text == "name,sold\nB,11\nA,9\n")
        table.sortDescriptors = [NSSortDescriptor(key: "1", ascending: true)]
        #expect(grid.tableView(table, objectValueFor: table.tableColumns[0], row: 0) as? String == "A")
        #expect(editor.text == "name,sold\nB,11\nA,9\n", "sorting shows; the file stays")
        editor.apply(text: "name,sold\nC,1\n", selection: NSRange(location: 0, length: 0))
        grid.changed(editor.text)
        #expect(table.numberOfRows == 1)
    }
}

extension OneAtATime {
    /// A page whose process ended (out of memory, a crash) is drawn again rather than left blank.
    @Test func aPageWhoseProcessEndedIsDrawnAgain() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-page-ended/notes.md")
        let tab = MarkdownTab(editor: CodeEditor(text: "# Notes", url: url), url: url, app: AppModel())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentViewController = tab
        #expect(try await waitFor(10) { MarkdownTab.loaded.object(forKey: tab) != nil })
        MarkdownTab.loaded.removeObject(forKey: tab)
        tab.links.webViewWebContentProcessDidTerminate(tab.web)
        #expect(try await waitFor(10) { MarkdownTab.loaded.object(forKey: tab) != nil })
    }
}

extension OneAtATime {
    /// Edit › Find with the page focused shows the find card over the page, not a beep.
    @Test func findOnThePageShowsItsFindCard() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-page-find/notes.md")
        let tab = MarkdownTab(editor: CodeEditor(text: "# Notes\n\nfind me", url: url), url: url, app: AppModel())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentViewController = tab
        #expect(try await waitFor(10) { MarkdownTab.loaded.object(forKey: tab) != nil })
        window.makeFirstResponder(tab.web)
        let find = NSMenuItem(
            title: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        #expect(
            NSApp.sendAction(find.action!, to: nil, from: find)
                || window.firstResponder?.tryToPerform(find.action!, with: find) == true)
        func cards(_ v: NSView) -> Int { (v is FindCard ? 1 : 0) + v.subviews.map(cards).reduce(0, +) }
        #expect(cards(tab.view) == 1)
    }
}
