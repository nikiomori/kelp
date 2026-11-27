import AppKit

extension NSBezierPath {
    /// The path SVG path data draws ("M2 8a6 6 0 1 0 12 0z…"), in the data's own units and y-down, as a flipped view
    /// or image draws it. It reads the whole path grammar (M L H V C S Q T A Z, absolute and relative), so a shape
    /// drawn in a browser, or copied from an icon set drawn on the same rules (Lucide's), is the same drawing here.
    public convenience init(svg data: String) {
        self.init()
        var scan = PathScanner(Array(data.utf8))
        var command: UInt8 = UInt8(ascii: "M")
        var point = NSPoint.zero, start = NSPoint.zero
        var lastCubic: NSPoint?, lastQuad: NSPoint?   // the control point S and T mirror
        while let next = scan.command(after: command) {
            command = next
            let relative = command >= UInt8(ascii: "a")
            func at(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                relative ? NSPoint(x: point.x + x, y: point.y + y) : NSPoint(x: x, y: y)
            }
            func pair() -> NSPoint { at(scan.number(), scan.number()) }
            var cubic: NSPoint?, quad: NSPoint?
            switch command | 0x20 {   // lower case
            case UInt8(ascii: "m"):
                point = pair()
                start = point
                move(to: point)
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")   // pairs after a move are lines
            case UInt8(ascii: "l"):
                point = pair()
                line(to: point)
            case UInt8(ascii: "h"):
                let x = scan.number()
                point = NSPoint(x: relative ? point.x + x : x, y: point.y)
                line(to: point)
            case UInt8(ascii: "v"):
                let y = scan.number()
                point = NSPoint(x: point.x, y: relative ? point.y + y : y)
                line(to: point)
            case UInt8(ascii: "c"), UInt8(ascii: "s"):
                let first = command | 0x20 == UInt8(ascii: "c") ? pair() : mirror(lastCubic, point)
                let second = pair(), end = pair()
                curve(to: end, controlPoint1: first, controlPoint2: second)
                (point, cubic) = (end, second)
            case UInt8(ascii: "q"), UInt8(ascii: "t"):
                let control = command | 0x20 == UInt8(ascii: "q") ? pair() : mirror(lastQuad, point)
                let end = pair()
                curve(to: end, controlPoint: control)
                (point, quad) = (end, control)
            case UInt8(ascii: "a"):
                let rx = scan.number(), ry = scan.number(), turn = scan.number()
                let large = scan.flag(), sweep = scan.flag(), end = pair()
                arc(from: point, to: end, radii: (rx, ry), degrees: turn, flags: (large, sweep))
                point = end
            case UInt8(ascii: "z"):
                close()
                point = start
            default:
                return   // not path data: draw what came before
            }
            (lastCubic, lastQuad) = (cubic, quad)
        }
    }

    private func mirror(_ control: NSPoint?, _ point: NSPoint) -> NSPoint {
        control.map { NSPoint(x: 2 * point.x - $0.x, y: 2 * point.y - $0.y) } ?? point
    }

    /// An elliptical arc as SVG gives it, by its two ends (SVG 1.1, appendix F.6), drawn as curves of a quarter turn
    /// or less.
    private func arc(
        from p0: NSPoint, to p1: NSPoint, radii: (CGFloat, CGFloat), degrees: CGFloat, flags: (large: Bool, sweep: Bool)
    ) {
        var (rx, ry) = (abs(radii.0), abs(radii.1))
        let (large, sweep) = flags
        guard p0 != p1 else { return }
        guard rx > 0, ry > 0 else { return line(to: p1) }
        let phi = degrees * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let grow = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if grow > 1 { (rx, ry) = (rx * grow.squareRoot(), ry * grow.squareRoot()) }   // too small to reach: scale up
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let coef = (large != sweep ? 1 : -1) * max(0, num / (rx * rx * y1 * y1 + ry * ry * x1 * x1)).squareRoot()
        let cx1 = coef * rx * y1 / ry, cy1 = -coef * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let start = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var span = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && span > 0 { span -= 2 * .pi }
        if sweep && span < 0 { span += 2 * .pi }
        let pieces = max(1, Int((abs(span) / (.pi / 2)).rounded(.up))), step = span / CGFloat(pieces)
        let handle = 4 / 3 * tan(step / 4)
        func place(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: cosPhi * rx * x - sinPhi * ry * y + cx, y: sinPhi * rx * x + cosPhi * ry * y + cy)
        }
        for piece in 0..<pieces {
            let a = start + CGFloat(piece) * step, b = a + step
            curve(
                to: piece == pieces - 1 ? p1 : place(cos(b), sin(b)),
                controlPoint1: place(cos(a) - handle * sin(a), sin(a) + handle * cos(a)),
                controlPoint2: place(cos(b) + handle * sin(b), sin(b) - handle * cos(b)))
        }
    }
}

/// Reads path data: command letters, and numbers that run together as SVG lets them ("1.5-1.5", ".5.5").
private struct PathScanner {
    let bytes: [UInt8]
    var index = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    private mutating func skip() {
        while index < bytes.count, [0x20, 0x2C, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    /// The next command: a letter, or the last one again when numbers follow it. nil at the end.
    mutating func command(after last: UInt8) -> UInt8? {
        skip()
        guard index < bytes.count else { return nil }
        let byte = bytes[index]
        if (byte | 0x20) >= UInt8(ascii: "a"), (byte | 0x20) <= UInt8(ascii: "z"),
            byte | 0x20 != UInt8(ascii: "e")
        {
            index += 1
            return byte
        }
        return last | 0x20 == UInt8(ascii: "z") ? nil : last
    }

    mutating func number() -> CGFloat {
        skip()
        let begin = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
        var dot = false
        while index < bytes.count {
            let byte = bytes[index]
            if byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                index += 1
            } else if byte == UInt8(ascii: "."), !dot {
                dot = true
                index += 1
            } else if byte | 0x20 == UInt8(ascii: "e") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") {
                    index += 1
                }
            } else {
                break
            }
        }
        guard index > begin else {   // not a number: step past it so a bad path ends rather than loops
            index += 1
            return 0
        }
        return CGFloat(Double(String(decoding: bytes[begin..<index], as: UTF8.self)) ?? 0)
    }

    /// An arc's flag, which SVG lets stand against what follows ("0 012-2").
    mutating func flag() -> Bool {
        skip()
        guard index < bytes.count else { return false }
        index += 1
        return bytes[index - 1] == UInt8(ascii: "1")
    }
}
