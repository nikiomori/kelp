import AVFoundation
import AppKit
import Foundation
import Testing

@testable import BuiltinFiles

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
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-tone-\(UUID().uuidString).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
    buffer.frameLength = 8000
    for i in 0..<8000 { buffer.floatChannelData?[0][i] = i < 4000 ? 0.5 * sin(Float(i) / 3) : 0 }
    try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    let bars = MarkdownTab.loudness(of: url)
    #expect(bars.count == 20 && bars[0] > 0.45 && bars[19] == 0)
}
