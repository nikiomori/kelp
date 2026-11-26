import AppKit
import QuartzCore

/// The desktop's picture redrawn in a print's dots of its own colours (big where it is light, small where it is dark),
/// under the editor area of a `halftone` theme. It lines up with the desktop round the window and dims down to the
/// card's colour, so the code on it reads. The picture is the file macOS shows (no screen recording), drawn once for
/// each picture and screen: moving the window only moves it.
@MainActor
final class Halftone {
    let dots = CALayer(), shade = CAGradientLayer()
    private var drawn: (url: URL, size: NSSize)?
    private var drawing: Task<Void, Never>?
    nonisolated static let cell: CGFloat = 6

    init() {
        // The dots stay put on the desktop while the window moves, and a new picture shows at once: nothing slides or
        // fades.
        let still: [String: any CAAction] = [
            "position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "colors": NSNull()
        ]
        dots.actions = still
        shade.actions = still
    }

    /// Lines the dots up with the desktop under `view`, drawing them anew for another picture or screen.
    func place(in view: NSView, base: NSColor) {
        shade.frame = view.bounds
        // Layer space runs up: the first colour is the card's foot.
        shade.colors = [base.cgColor, NSColor.clear.cgColor]
        shade.locations = [0.08, 0.9]
        guard let window = view.window, let screen = window.screen else { return }
        let at = window.convertToScreen(view.convert(view.bounds, to: nil)), size = screen.frame.size
        dots.frame = CGRect(
            x: screen.frame.minX - at.minX, y: screen.frame.minY - at.minY, width: size.width, height: size.height)
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen), drawn?.url != url || drawn?.size != size
        else { return }
        drawn = (url, size)
        let scale = screen.backingScaleFactor
        drawing?.cancel()
        drawing = Task { [dots] in
            let picture = await Task.detached { Self.picture(url, size: size, scale: scale) }.value
            guard !Task.isCancelled else { return }
            dots.contentsScale = scale
            dots.contents = picture
        }
    }

    /// Draws the picture at `url`, filling a screen of `size` as the desktop does, in dots: one a cell, its size from
    /// the cell's lightness, its colour the cell's own a little dimmed. Nil when the file isn't a picture (a moving
    /// wallpaper's video): the card keeps its colour.
    /// Limit: a whole screen's bitmap (about 30 MB on a 2× display), held while the theme is on.
    nonisolated static func picture(_ url: URL, size: NSSize, scale: CGFloat) -> CGImage? {
        guard let source = NSImage(contentsOf: url), source.size.width > 0, source.size.height > 0 else { return nil }
        let columns = Int(size.width / cell) + 1, rows = Int(size.height / cell) + 1
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        // One pixel a cell: drawing the picture this small averages each cell's colour.
        guard
            let small = CGContext(
                data: nil, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns * 4, space: space,
                bitmapInfo: info),
            let big = CGContext(
                data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                bytesPerRow: 0, space: space, bitmapInfo: info)
        else { return nil }
        let fill = max(CGFloat(columns) / source.size.width, CGFloat(rows) / source.size.height)
        let drawnSize = CGSize(width: source.size.width * fill, height: source.size.height * fill)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: small, flipped: false)
        source.draw(
            in: CGRect(
                x: (CGFloat(columns) - drawnSize.width) / 2, y: (CGFloat(rows) - drawnSize.height) / 2,
                width: drawnSize.width, height: drawnSize.height))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = small.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        big.scaleBy(x: scale, y: scale)
        for row in 0..<rows {
            for column in 0..<columns {
                let pixel = data + (row * columns + column) * 4
                let (red, green, blue) = (CGFloat(pixel[0]) / 255, CGFloat(pixel[1]) / 255, CGFloat(pixel[2]) / 255)
                let radius = dot(lightness: 0.2126 * red + 0.7152 * green + 0.0722 * blue)
                guard radius > 0 else { continue }
                // The bitmap's first row is the picture's top; the drawing runs up.
                let center = CGPoint(
                    x: (CGFloat(column) + 0.5) * cell, y: size.height - (CGFloat(row) + 0.5) * cell)
                big.setFillColor(red: red * 0.8, green: green * 0.8, blue: blue * 0.8, alpha: 1)
                big.fillEllipse(
                    in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
        }
        return big.makeImage()
    }

    /// A dot's radius for a cell's lightness (0…1): by area, so twice as light covers twice as much; none for black.
    nonisolated static func dot(lightness: CGFloat) -> CGFloat {
        let radius = cell * 0.55 * lightness.squareRoot()
        return radius < 0.4 ? 0 : radius
    }
}
