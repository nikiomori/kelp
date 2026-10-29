import SwiftUI

/// Parts of a whole side by side in a fixed order, the free rest hatched, as Storage in System Settings draws a disk;
/// `end`, a part kept at the far end (room held back). The legend under it marks each part with `Swatch`. Its parts grow
/// and shrink when they change.
public struct PartsBar: View {
    public struct Part: Identifiable, Equatable {
        public let id: String, value: Double, color: Color
        public init(id: String, value: Double, color: Color) { self.id = id; self.value = value; self.color = color }
    }
    public static let height: CGFloat = 8
    let parts: [Part], total: Double, end: Part?

    public init(_ parts: [Part], total: Double, end: Part? = nil) { self.parts = parts; self.total = total; self.end = end }

    public var body: some View {
        GeometryReader { g in
            let room = g.size.width - CGFloat(parts.count + (end == nil ? 0 : 1))   // a point between parts
            let width = { (p: Part) in max(1, room * min(1, p.value / max(1, total))) }
            HStack(spacing: 1) {
                ForEach(parts) { p in Rectangle().fill(p.color).frame(width: width(p)) }
                Hatch()
                if let end { Rectangle().fill(end.color).frame(width: width(end)) }
            }
        }
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusXS))
        .animation(.easeOut(duration: Motion.duration(Motion.base)), value: parts)
    }

    /// The free rest: thin diagonal lines over the resting fill.
    struct Hatch: View {
        var body: some View {
            Canvas { c, size in
                var p = Path(), x = -size.height
                while x < size.width {
                    p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x + size.height, y: 0)); x += 4
                }
                c.stroke(p, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
            }
            .background(Color(nsColor: .fillRest))
        }
    }

    /// A part's colour in the legend, a square as tall as the bar; nil: the free rest's hatching.
    public struct Swatch: View {
        let color: Color?
        public init(_ color: Color?) { self.color = color }
        public var body: some View {
            let shape = RoundedRectangle(cornerRadius: Metrics.radiusXS / 2)
            Group { if let color { shape.fill(color) } else { Hatch().clipShape(shape) } }
                .frame(width: PartsBar.height, height: PartsBar.height)
        }
    }
}
