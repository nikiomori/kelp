// The agent strip's gestures without a window: where a throw lands, where a swipe goes.
import AppKit

/// Which way two fingers went over the strip.
enum StripSwipe: Equatable { case left, right, up, down }

/// Where a gesture sends the strip: one of its six places, or behind a side.
enum StripTarget: Equatable {
    case corner(StripCorner)
    case edge(StripEdge)
}

extension StripModel {
    /// Faster than this when let go, it was thrown: it goes where it was heading, not to the place nearest the pointer.
    static let throwSpeed: CGFloat = 500
    /// How far ahead of where it was let go a throw lands, in seconds of its speed: as a picture-in-picture video flies on.
    static let throwReach: CGFloat = 0.3
    /// Two fingers going this far over the strip are a swipe.
    static let swipeDistance: CGFloat = 40

    /// Where a strip let go at `frame` going at `velocity` (points a second) would come to rest.
    static func projected(_ frame: NSRect, velocity: CGVector) -> NSRect {
        guard hypot(velocity.dx, velocity.dy) >= throwSpeed else { return frame }
        return frame.offsetBy(dx: velocity.dx * throwReach, dy: velocity.dy * throwReach)
    }

    /// The finger's way from a swipe's scroll: AppKit's deltas follow the content, which natural scrolling turns round.
    static func swipe(dx: CGFloat, dy: CGFloat, natural: Bool) -> StripSwipe? {
        let x = natural ? dx : -dx, down = natural ? dy : -dy
        guard max(abs(x), abs(down)) >= swipeDistance else { return nil }
        return abs(x) > abs(down) ? (x > 0 ? .right : .left) : (down > 0 ? .down : .up)
    }

    /// The next place along a swipe: a step along its row of three, across to the other row, behind the side it was
    /// swiped into from that side's corner, and out of it to that side's corner.
    static func swiped(from corner: StripCorner, edge: StripEdge?, _ way: StripSwipe) -> StripTarget? {
        if let edge {
            let out = edge == .left ? way == .right : way == .left
            guard out else { return nil }
            return .corner(
                edge == .left ? (corner.isTop ? .topLeft : .bottomLeft) : (corner.isTop ? .topRight : .bottomRight))
        }
        let rows: [[StripCorner]] = [[.topLeft, .top, .topRight], [.bottomLeft, .bottom, .bottomRight]]
        let row = corner.isTop ? 0 : 1, column = rows[row].firstIndex(of: corner) ?? 1
        switch way {
        case .up: return corner.isTop ? nil : .corner(rows[0][column])
        case .down: return corner.isTop ? .corner(rows[1][column]) : nil
        case .left: return column == 0 ? .edge(.left) : .corner(rows[row][column - 1])
        case .right: return column == 2 ? .edge(.right) : .corner(rows[row][column + 1])
        }
    }
}
