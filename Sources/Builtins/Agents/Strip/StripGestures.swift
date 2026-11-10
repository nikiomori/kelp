// The agent strip's gestures without a window: which way a throw or a swipe went, and where that sends it.
import AppKit

/// Which way a throw or a swipe went: x and y are each -1, 0 or 1 (y up), so a slanted one goes to a corner.
struct StripWay: Equatable {
    let x: Int, y: Int
}

/// Where a gesture sends the strip: one of its six places, or behind a side.
enum StripTarget: Equatable {
    case corner(StripCorner)
    case edge(StripEdge)
}

extension StripModel {
    /// Faster than this when let go (points a second), it was thrown: it flies on that way, not to the nearest place.
    static let throwSpeed: CGFloat = 600
    /// Two fingers going this far over the strip are a swipe: it flies at once, not when they lift.
    static let swipeDistance: CGFloat = 30
    /// Across this much of the main way (tan 26.6°), it went slanted: to a corner of the other row too.
    private static let slant: CGFloat = 0.5

    /// The way of a move, if it went anywhere.
    static func way(_ v: CGVector) -> StripWay? {
        let major = max(abs(v.dx), abs(v.dy))
        guard major > 0 else { return nil }
        func axis(_ d: CGFloat) -> Int { abs(d) < major * slant ? 0 : d > 0 ? 1 : -1 }
        return StripWay(x: axis(v.dx), y: axis(v.dy))
    }

    /// The way it was thrown, if it was.
    static func thrown(_ velocity: CGVector) -> StripWay? {
        hypot(velocity.dx, velocity.dy) >= throwSpeed ? way(velocity) : nil
    }

    /// The finger's way from a swipe's scroll: AppKit's deltas follow the content, which natural scrolling turns round.
    static func swipe(dx: CGFloat, dy: CGFloat, natural: Bool) -> StripWay? {
        let x = natural ? dx : -dx, up = natural ? -dy : dy
        guard hypot(x, up) >= swipeDistance else { return nil }
        return way(CGVector(dx: x, dy: up))
    }

    /// As far as it goes that way: to that side's corner of its row (the other row's, slanted), behind the side from that
    /// side's corner, and out from behind a side to its corner.
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
}
