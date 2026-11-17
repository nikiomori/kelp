// The agent strip's gestures, worked out without a window: which way a throw or a swipe went, and where that sends
// the strip.
import AppKit

/// Which way a throw or a swipe went. x and y are each -1, 0 or 1, with y up, so a slanted move goes to a corner.
struct StripWay: Equatable {
    let x: Int, y: Int
}

/// Where a gesture sends the strip: one of its six places, or behind a side.
enum StripTarget: Equatable {
    case corner(StripCorner)
    case edge(StripEdge)
}

extension StripModel {
    /// A strip let go faster than this, in points a second, was thrown, so it flies on that way instead of going to the
    /// nearest place.
    static let throwSpeed: CGFloat = 600
    /// Two fingers moving this far over the strip make a swipe, and the strip flies at once, not when they lift.
    static let swipeDistance: CGFloat = 30
    /// A move whose cross part is at least this share of its main part (tan 26.6°) counts as slanted, so it also goes
    /// to a corner in the other row.
    private static let slant: CGFloat = 0.5

    /// Returns which way a move went, or nil if it went nowhere.
    static func way(_ vector: CGVector) -> StripWay? {
        let major = max(abs(vector.dx), abs(vector.dy))
        guard major > 0 else { return nil }
        func axis(_ d: CGFloat) -> Int { abs(d) < major * slant ? 0 : d > 0 ? 1 : -1 }
        return StripWay(x: axis(vector.dx), y: axis(vector.dy))
    }

    /// Returns which way the strip was thrown, or nil if it wasn't thrown.
    static func thrown(_ velocity: CGVector) -> StripWay? {
        hypot(velocity.dx, velocity.dy) >= throwSpeed ? way(velocity) : nil
    }

    /// Returns which way the fingers moved in a swipe's scroll. AppKit's deltas follow the content, which natural
    /// scrolling turns round.
    static func swipe(dx: CGFloat, dy: CGFloat, natural: Bool) -> StripWay? {
        let x = natural ? dx : -dx, up = natural ? -dy : dy
        guard hypot(x, up) >= swipeDistance else { return nil }
        return way(CGVector(dx: x, dy: up))
    }

    /// Returns where a fling in that direction lands, as far as it can go. It lands in that side's corner of the
    /// strip's row, or of the other row for a slanted fling. A fling from that side's corner goes behind the side, and
    /// a fling away from a side brings the strip out to that side's corner.
    static func flung(from corner: StripCorner, edge: StripEdge?, _ way: StripWay) -> StripTarget? {
        let high = way.y == 0 ? corner.isTop : way.y > 0
        if let edge {
            guard way.x == (edge == .left ? 1 : -1) else { return nil }
            return .corner(edge == .left ? (high ? .topLeft : .bottomLeft) : (high ? .topRight : .bottomRight))
        }
        let rows: [[StripCorner]] = [[.topLeft, .top, .topRight], [.bottomLeft, .bottom, .bottomRight]]
        let column = way.x == 0 ? rows[corner.isTop ? 0 : 1].firstIndex(of: corner) ?? 1 : way.x + 1
        let to = rows[high ? 0 : 1][column]
        if to != corner { return .corner(to) }
        return way.x == 0 ? nil : .edge(way.x < 0 ? .left : .right)
    }

    /// Returns where a spring swings to: a little past `frame` on the way from `from`, by a tenth of the way and at
    /// most `swing`.
    static func past(_ frame: NSRect, from: NSRect) -> NSRect {
        let dx = frame.midX - from.midX, dy = frame.midY - from.midY, way = hypot(dx, dy)
        guard way > 0 else { return frame }
        let by = min(swing, way / 10) / way
        return frame.offsetBy(dx: dx * by, dy: dy * by)
    }

    /// How far past its place a moved strip swings before it settles.
    static let swing: CGFloat = 10
}
