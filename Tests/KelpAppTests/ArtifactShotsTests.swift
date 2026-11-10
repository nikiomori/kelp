import AppKit
import Testing

@testable import BuiltinFiles

/// The Artifacts card shows a picture of the page laid out as wide as a desktop window, not the page squeezed into the
/// card: a page that is red only at 1000 pt or wider comes out red, at the card's width and proportions.
@MainActor @Test func anArtifactsPictureIsThePageAtADesktopsWidth() async throws {
    let html = """
        <style>body { margin: 0; height: 100vh; background: rgb(0, 0, 255) }
        @media (min-width: 1000px) { body { background: rgb(255, 0, 0) } }</style>
        """
    let image = try #require(
        await ArtifactShots().picture(
            html: html, base: URL(fileURLWithPath: NSTemporaryDirectory()), key: "t", dark: false, board: false))
    #expect(image.size.width == ArtifactCard.size.width)
    #expect(abs(image.size.height / image.size.width - ArtifactCard.size.height / ArtifactCard.size.width) < 0.01)
    let rep = NSBitmapImageRep(cgImage: try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
    let middle = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
    #expect(middle.redComponent > 0.8 && middle.blueComponent < 0.3, "\(middle)")
}
