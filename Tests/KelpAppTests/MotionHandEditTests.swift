import AppKit
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
