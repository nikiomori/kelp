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
