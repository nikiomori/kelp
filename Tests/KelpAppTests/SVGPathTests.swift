import AppKit
import Testing

@testable import DesignKit

/// Path data draws the shape a browser draws: arcs, relative moves, numbers run together, curves.
@Test(arguments: [
    ("M2 8a6 6 0 1 0 12 0a6 6 0 1 0 -12 0z", NSRect(x: 2, y: 2, width: 12, height: 12)),   // a ring of two arcs
    ("M1 1h3v2H1z", NSRect(x: 1, y: 1, width: 3, height: 2)),
    ("M0 0l1.5-1.5.5.5", NSRect(x: 0, y: -1.5, width: 2, height: 1.5)),   // "1.5-1.5.5.5" is four numbers
    ("M1 1 3 3", NSRect(x: 1, y: 1, width: 2, height: 2)),   // pairs after a move are lines
    ("M0 4a4 4 0 0 1 8 0", NSRect(x: 0, y: 0, width: 8, height: 4)),   // sweep 1 goes up, as y runs down
    ("M0 4a4 4 0 0 0 8 0", NSRect(x: 0, y: 4, width: 8, height: 4))
])
func svgPathDrawsWhatABrowserDraws(data: String, bounds: NSRect) {
    let drawn = NSBezierPath(svg: data).bounds
    #expect(abs(drawn.minX - bounds.minX) < 0.01 && abs(drawn.minY - bounds.minY) < 0.01)
    #expect(abs(drawn.width - bounds.width) < 0.01 && abs(drawn.height - bounds.height) < 0.01)
}

/// Every glyph is drawn, and inside its 16-point grid: a typo in its path data would draw nothing or run off it.
@Test func everyGlyphDrawsInsideItsGrid() {
    for (name, data) in Glyph.shapes {
        let bounds = NSBezierPath(svg: data).bounds
        #expect(bounds.width > 4 && bounds.height > 1, "\(name)")
        #expect(NSRect(x: 0.5, y: 0.5, width: 15, height: 15).contains(bounds), "\(name): \(bounds)")
    }
}
