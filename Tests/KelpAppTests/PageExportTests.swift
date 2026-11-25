import AVFoundation
import AppKit
import Core
import Foundation
import PDFKit
import TestSupport
import Testing

@testable import BuiltinFiles
@testable import EditorKit
@testable import KelpKit

/// A PowerPoint of pictures has its parts: a slide and a picture for each, each slide in the deck's list and in the
/// package's types.
@MainActor @Test func aPowerPointHoldsASlideForEachPicture() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-pptx-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let red = NSImage(size: NSSize(width: 16, height: 9), flipped: false) { r in
        NSColor.red.setFill()
        r.fill()
        return true
    }
    let png = try #require(MarkdownTab.png(red, width: 160, height: 90))
    try PowerPoint.write([png, png], into: folder)
    let read = { (path: String) in
        String(
            decoding: FileManager.default.contents(atPath: folder.appendingPathComponent(path).path) ?? Data(),
            as: UTF8.self)
    }
    #expect(read("ppt/presentation.xml").components(separatedBy: "<p:sldId ").count == 3)
    #expect(read("[Content_Types].xml").contains("/ppt/slides/slide2.xml"))
    #expect(read("ppt/slides/_rels/slide2.xml.rels").contains("../media/image2.png"))
    #expect(FileManager.default.contents(atPath: folder.appendingPathComponent("ppt/media/image1.png").path) == png)
    if ProcessInfo.processInfo.environment["KELP_KEEP_PPTX"] != nil {
        try FileManager.default.copyItem(at: folder, to: URL(fileURLWithPath: "/tmp/kmr-shots/pptx-parts"))
    }
}

/// A board with no height of its own is drawn as tall as its content (the canvas sets `h` only for fixed frames), and
/// a board of a row is drawn from the HTML given for it.
@MainActor @Test func aBoardIsDrawnAsTallAsItsContent() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-board-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("a.html")
    try #"<body style="margin:0"><div style="height:300px">a</div></body>"#.write(
        to: file, atomically: true, encoding: .utf8)
    let tall = try #require(NSBitmapImageRep(data: try await MarkdownTab.picture(of: file, width: 200, height: nil)))
    #expect(tall.pixelsWide == 400 && tall.pixelsHigh == 600)
    let row = #"<body style="margin:0"><div style="height:150px">b</div></body>"#
    let drawn = try #require(
        NSBitmapImageRep(data: try await MarkdownTab.picture(of: file, html: row, width: 200, height: nil)))
    #expect(drawn.pixelsHigh == 300)
}

/// A page's own pictures and stylesheets go inside it; a path outside its folder or on the web stays a link.
@Test func aPageGoesIntoOneFile() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-inline-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("img"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data([1, 2, 3]).write(to: folder.appendingPathComponent("img/a.png"))
    try "h1{color:red}".write(to: folder.appendingPathComponent("s.css"), atomically: true, encoding: .utf8)
    let page =
        #"<link rel="stylesheet" href="s.css"><img src="img/a.png"><img src="../x.png"><img src="https://e.com/b.png">"#
    #expect(
        PageInline.inline(page, folder: folder)
            == #"<style>h1{color:red}</style><img src="data:image/png;base64,AQID"><img src="../x.png"><img src="https://e.com/b.png">"#
    )
}

/// A frame on black and on white gives its transparency: a half-clear red reads as red at half, the background as
/// nothing, and a solid pixel as itself.
@Test func aTransparentFrameComesFromBlackAndWhite() throws {
    func image(_ pixels: [UInt8]) throws -> CGImage {
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(
            CGImage(
                width: 3, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 12,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    let black = try image([128, 0, 0, 255, 0, 0, 0, 255, 10, 200, 30, 255])
    let white = try image([255, 127, 127, 255, 255, 255, 255, 255, 10, 200, 30, 255])
    let out = try #require(MotionExports.matte(black: black, white: white, width: 3, height: 1))
    let bytes = try #require(out.dataProvider?.data as Data?)
    #expect(Array(bytes.prefix(12)) == [128, 0, 0, 128, 0, 0, 0, 0, 10, 200, 30, 255])
}

/// A video made is opened again and held to what was asked: a GIF of 3 frames at 10 a second, 4×2, passes; asked
/// as 8×2 and half a second long, it says both.
@Test func aMadeVideoIsCheckedAgainstWhatWasAsked() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-verify-\(UUID().uuidString).gif")
    defer { try? FileManager.default.removeItem(at: url) }
    let gif = try MotionGIF(url, frames: 3, fps: 10)
    let context = try #require(
        CGContext(
            data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    for i in 0..<3 {   // each its own colour, or ImageIO makes one long frame of them
        context.setFillColor(CGColor(red: CGFloat(i) / 2, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        gif.add(try #require(context.makeImage()))
    }
    try gif.finish()
    let good = await MotionVerify.check(url, .init(width: 4, height: 2, fps: 10, duration: 0.3), warnings: [])
    #expect(good.ok && good.summary.hasPrefix("✓ 4×2 · 10 fps · 0.3 s"))
    let off = await MotionVerify.check(url, .init(width: 8, height: 2, fps: 10, duration: 0.5), warnings: [])
    #expect(!off.ok && off.problems.count == 2)
}

/// A video's frames fall before its end (a scene ending there is gone at that second), and a GIF at 30 a second
/// lasts as long as asked though its delays are whole hundredths.
@Test func aVideosFramesLastAsLongAsAsked() async throws {
    #expect(MarkdownTab.frameTimes(5, fps: 30).count == 150 && MarkdownTab.frameTimes(5, fps: 30).last! < 5)
    #expect(MarkdownTab.frameTimes(0.3, fps: 10).count == 3)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-gif30-\(UUID().uuidString).gif")
    defer { try? FileManager.default.removeItem(at: url) }
    let gif = try MotionGIF(url, frames: 30, fps: 30)
    let context = try #require(
        CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    for i in 0..<30 {   // each its own colour, or ImageIO makes one long frame of them
        context.setFillColor(CGColor(red: CGFloat(i % 5) / 4, green: CGFloat(i / 5) / 5, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        gif.add(try #require(context.makeImage()))
    }
    try gif.finish()
    let made = await MotionVerify.check(url, .init(width: 2, height: 2, fps: 30, duration: 1), warnings: [])
    #expect(made.ok && abs(made.duration - 1) < 0.001, "\(made.duration) \(made.problems)")
}

/// Build in Code guesses a web project's stack from its package.json, the most particular first.
@MainActor
@Test(arguments: [
    (#"{"dependencies": {"next": "15", "react": "19"}}"#, "Next.js"), (#"{"dependencies": {"react": "19"}}"#, "React"),
    (#"{"devDependencies": {"svelte": "5"}}"#, "Svelte"), (#"{"dependencies": {"vue": "3"}}"#, "Vue"),
    ("{}", "HTML and CSS")
])
func buildInCodeGuessesTheStack(json: String, stack: String) {
    #expect(MarkdownTab.stack(packageJSON: json) == stack)
}

/// Adaptations go to the agent as one request: every format chosen, laid out again rather than cropped, then exported.
@MainActor @Test func adaptationsAreOneRequest() {
    let line = MarkdownTab.adaptations(
        page: ".kelp/artifacts/launch/motion.html", formats: [("9:16", 1080, 1920), ("1:1", 1080, 1080)], length: "6 s")
    #expect(line.contains("for 9:16 (1080 × 1920), 1:1 (1080 × 1080)") && line.contains("6 s long"))
    #expect(line.contains("not cropped") && line.hasSuffix("kelp artifact export <name> mp4."))
}

/// A motion page's sounds come with their times, volume and fades; a work area cuts off what comes before it. Their
/// loudness is read 20 bars a second.
@MainActor @Test func aPagesSoundsAndTheirLoudness() throws {
    let page =
        #"<audio data-id="a" data-start="1" data-duration="4" data-volume="80" data-fade-in="0.5" src="v.m4a"></audio>"#
    let folder = URL(fileURLWithPath: "/tmp/p")
    #expect(
        MotionSound.sounds(in: page, folder: folder)
            == [
                .init(
                    file: folder.appendingPathComponent("v.m4a"), start: 1, from: 0, length: 4, volume: 0.8,
                    fadeIn: 0.5, fadeOut: 0)
            ])
    let late = try #require(MotionSound.sounds(in: page, folder: folder, from: 2).first)
    #expect((late.start, late.from, late.length) == (0, 1, 3))
    // Music quieter under a voice: 12 dB down while it speaks, sloping 0.3 s either side; brought to −14 LUFS.
    let two =
        #"<audio data-start="0" data-duration="6" data-duck="12" data-loudness="-14" src="m.m4a"></audio>"#
        + #"<audio data-start="1" data-duration="2" src="v.m4a"></audio>"#
    let music = try #require(MotionSound.sounds(in: two, folder: folder).first)
    #expect(music.ducks == [1...3] && music.loudness == -14)
    #expect(music.level(at: 0.5) == 1 && abs(music.level(at: 2) - 0.251) < 0.001)
    #expect(music.level(at: 0.85) > 0.251 && music.level(at: 0.85) < 1)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-tone-\(UUID().uuidString).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
    buffer.frameLength = 8000
    for i in 0..<8000 { buffer.floatChannelData?[0][i] = i < 4000 ? 0.5 * sin(Float(i) / 3) : 0 }
    try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    let (all, rate) = try Beats.samples(of: url)
    let bars = MarkdownTab.loudness(all, rate: rate)
    #expect(bars.count == 20 && bars[0] > 0.45 && bars[19] == 0)
}

/// A GIF made to play again and again says so (a loop count of 0); one made to play once has none, which reads as
/// one play.
@Test func aGIFLoopsOrPlaysOnce() throws {
    let context = try #require(
        CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let frame = try #require(context.makeImage())
    for once in [false, true] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let gif = try MotionGIF(url, frames: 2, fps: 10, once: once)
        gif.add(frame)
        gif.add(frame)
        try gif.finish()
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let gifInfo = (CGImageSourceCopyProperties(source, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary]
        let count = (gifInfo as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
        #expect(count == (once ? 1 : 0), "once: \(once)")   // ImageIO reads no loop count as one play
    }
}

/// A click on the bird in a photo outlines the bird, as points across the picture; a corner of sky outlines nothing.
@Test func anObjectInAPhotoIsOutlined() throws {
    let file = URL(fileURLWithPath: "/Library/User Pictures/Animals/Parrot.heic")
    try #require(FileManager.default.fileExists(atPath: file.path))
    let outline = try #require(try ObjectOutline.outline(of: file, at: CGPoint(x: 0.5, y: 0.5)))
    #expect(outline.count > 20 && outline.count <= 170)
    let xs = outline.map(\.x), ys = outline.map(\.y)
    #expect((xs.min() ?? 0) < 0.5 && (xs.max() ?? 0) > 0.5 && (ys.min() ?? 0) < 0.5 && (ys.max() ?? 0) > 0.5)
    #expect(try ObjectOutline.outline(of: file, at: CGPoint(x: 0.02, y: 0.02)) == nil)
}

/// An editable PowerPoint's slide has its words as a text box over its picture: placed on the 16:9 slide, its size in
/// hundredths of a point, its colour and weight, each line a paragraph, the words escaped.
@Test func aSlidesWordsAreATextBox() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-pptx-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let text = PowerPoint.Text(
        x: 0.5, y: 0.25, w: 0.25, h: 0.1, words: "Q3 & beyond\n<next>", size: 40, bold: true, colour: "1D1D1F",
        align: "ctr")
    try PowerPoint.write([Data()], texts: [[text]], into: folder)
    let slide = try String(contentsOf: folder.appendingPathComponent("ppt/slides/slide1.xml"), encoding: .utf8)
    #expect(slide.contains(#"<a:off x="6096000" y="1714500"/><a:ext cx="3048000" cy="685800"/>"#))
    #expect(slide.contains(#"sz="4000" b="1""#) && slide.contains(#"<a:srgbClr val="1D1D1F"/>"#))
    #expect(slide.contains("<a:t>Q3 &amp; beyond</a:t>") && slide.contains("<a:t>&lt;next&gt;</a:t>"))
    #expect(slide.components(separatedBy: #"<a:pPr algn="ctr"/>"#).count == 3)
}

/// A deck made as a design leaves as slides do: a PDF page a board at the board's size, and a PowerPoint slide a board
/// whose words are a text box over its picture.
@MainActor @Test func aDeckMadeAsADesignLeavesAsSlides() async throws {
    _ = NSApplication.shared
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
        "kelp-deck-\(UUID().uuidString)/.kelp/artifacts/deck")
    try FileManager.default.createDirectory(
        at: folder.appendingPathComponent("boards"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
    for name in ["a", "b"] {
        try #"<body style="margin:0"><h1 style="margin:40px">Slide \#(name)</h1></body>"#.write(
            to: folder.appendingPathComponent("boards/\(name).html"), atomically: true, encoding: .utf8)
    }
    let canvas =
        #"{"boards": [{"file": "boards/a.html", "w": 1280, "h": 720}, {"file": "boards/b.html", "w": 1280, "h": 720}]}"#
    let url = folder.appendingPathComponent("canvas.json")
    try canvas.write(to: url, atomically: true, encoding: .utf8)
    let tab = MarkdownTab(editor: CodeEditor(text: canvas, url: url), url: url, app: AppModel())
    #expect(tab.isDeck)
    let pdf = folder.appendingPathComponent("deck.pdf")
    try await tab.exportBoardsPDF(pdf)
    let document = try #require(PDFDocument(url: pdf))
    #expect(document.pageCount == 2)
    #expect(document.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 1280, height: 720))
    #expect(document.page(at: 1)?.string?.contains("Slide b") == true)
    let (slides, texts) = try await tab.deckSlides(editable: true)
    #expect(slides.count == 2 && NSBitmapImageRep(data: slides[0])?.pixelsWide == 1920)
    #expect(texts.map { $0.map(\.words) } == [["Slide a"], ["Slide b"]])
}

/// A document leaves as Word with its words and headings.
@MainActor @Test func aDocumentLeavesAsWord() async throws {
    _ = NSApplication.shared
    let word = try MarkdownTab.word("# Plan\n\nShip **it**.\n\n- one\n- two", baseURL: nil)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-doc-\(UUID().uuidString)")
    let home = folder.appendingPathComponent(".kelp/artifacts/plan")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let docx = home.appendingPathComponent("plan.docx")
    try word.write(to: docx)
    let unzip = Process()
    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    unzip.arguments = ["-p", docx.path, "word/document.xml"]
    let out = Pipe()
    unzip.standardOutput = out
    try unzip.run()
    unzip.waitUntilExit()
    let xml = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(xml.contains("Plan") && xml.contains("Ship") && xml.contains("two"))
}

/// A document leaves as a PDF in A4 pages, as many as it needs.
@MainActor @Test func aDocumentLeavesAsPagesOfPDF() async throws {
    _ = NSApplication.shared
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-doc-\(UUID().uuidString)")
    let home = folder.appendingPathComponent(".kelp/artifacts/plan")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let text = "# Plan\n\n" + (1...120).map { "Paragraph \($0) of the plan." }.joined(separator: "\n\n")
    let url = home.appendingPathComponent("doc.md")
    try text.write(to: url, atomically: true, encoding: .utf8)
    let tab = MarkdownTab(editor: CodeEditor(text: text, url: url), url: url, app: AppModel())
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered,
        defer: false)
    window.contentViewController = tab
    #expect(try await waitFor(10) { MarkdownTab.loaded.object(forKey: tab) != nil })
    #expect(try await waitFor(10) { !tab.web.isLoading })
    let pdf = home.appendingPathComponent("plan.pdf")
    try await tab.exportDocumentPDF(pdf)
    let document = try #require(PDFDocument(url: pdf))
    #expect(document.pageCount > 1)
    #expect(abs((document.page(at: 0)?.bounds(for: .mediaBox).width ?? 0) - 595.3) < 1, "A4")
}

/// In an editable PowerPoint, a box filled with one colour is a shape (its corners rounded as drawn) and a table is a
/// table, both taken out of the slide's picture.
@MainActor @Test func aSlidesFilledBoxesAndTablesAreShapesAndTables() async throws {
    _ = NSApplication.shared
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
        "kelp-deck-\(UUID().uuidString)/.kelp/artifacts/q")
    try FileManager.default.createDirectory(
        at: folder.appendingPathComponent("boards"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
    let board = """
        <body style="margin:0"><div style="position:absolute;left:100px;top:100px;width:400px;height:200px;\
        background:#0a84ff;border-radius:20px">Card</div><table style="position:absolute;left:600px;top:100px">\
        <tr><th style="background:#eeeeee">Q</th><th>Sales</th></tr><tr><td>Q3</td><td>42</td></tr></table></body>
        """
    try board.write(to: folder.appendingPathComponent("boards/a.html"), atomically: true, encoding: .utf8)
    let canvas = #"{"boards": [{"file": "boards/a.html", "w": 1920, "h": 1080}]}"#
    let url = folder.appendingPathComponent("canvas.json")
    try canvas.write(to: url, atomically: true, encoding: .utf8)
    let tab = MarkdownTab(editor: CodeEditor(text: canvas, url: url), url: url, app: AppModel())
    let (_, texts) = try await tab.deckSlides(editable: true)
    let parts = try #require(texts.first)
    let card = try #require(parts.first { $0.fill == "0A84FF" })
    #expect(abs(card.radius - 0.1) < 0.01 && abs(card.x - 100.0 / 1920) < 0.001)
    #expect(parts.first { $0.cells != nil }?.cells == [["Q", "Sales"], ["Q3", "42"]])
    #expect(parts.first { $0.cells != nil }?.fill == "EEEEEE")
    #expect(parts.contains { $0.words == "Card" })
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-pptx-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: out) }
    try PowerPoint.write([Data()], texts: [parts], into: out)
    let slide = try String(contentsOf: out.appendingPathComponent("ppt/slides/slide1.xml"), encoding: .utf8)
    #expect(slide.contains(#"prst="roundRect""#) && slide.contains(#"<a:srgbClr val="0A84FF"/>"#))
    #expect(slide.contains("<a:tbl>") && slide.contains("<a:t>Sales</a:t>") && slide.contains(#"<a:gridCol w="#))
    if ProcessInfo.processInfo.environment["KELP_KEEP_PPTX"] != nil {
        try? FileManager.default.removeItem(atPath: "/tmp/kmr-shots/pptx-shapes")
        try FileManager.default.copyItem(at: out, to: URL(fileURLWithPath: "/tmp/kmr-shots/pptx-shapes"))
    }
}

/// A board copied as a picture is on the pasteboard as PNG, at twice its size.
@MainActor @Test func aBoardIsCopiedAsAPicture() async throws {
    _ = NSApplication.shared
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
        "kelp-copy-\(UUID().uuidString)/.kelp/artifacts/c")
    try FileManager.default.createDirectory(
        at: folder.appendingPathComponent("boards"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
    try "<p>Hi</p>".write(to: folder.appendingPathComponent("boards/a.html"), atomically: true, encoding: .utf8)
    let canvas = #"{"boards": [{"file": "boards/a.html", "w": 300, "h": 200}]}"#
    let url = folder.appendingPathComponent("canvas.json")
    let tab = MarkdownTab(editor: CodeEditor(text: canvas, url: url), url: url, app: AppModel())
    NSPasteboard.general.clearContents()
    tab.copyBoard("boards/a.html")
    #expect(try await waitFor(10) { NSPasteboard.general.data(forType: .png) != nil })
    let rep = try #require(NSPasteboard.general.data(forType: .png).flatMap(NSBitmapImageRep.init(data:)))
    #expect(rep.pixelsWide == 600 && rep.pixelsHigh == 400)
}
