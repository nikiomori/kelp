import AppKit
import DesignKit

/// Keyframes on the element lanes: a diamond at each keyframe of an element's first animation. A click chooses one and
/// moves the time to it; a drag moves it between its neighbours (the first and the last stay); a right click asks for
/// its menu (easing, move to the time, delete).
extension MotionTimeline {
    /// An animation's keyframes: its @keyframes rule, when and how long it runs, each keyframe's place (0–100) and the
    /// easing of the stretch after it.
    struct Keys: Equatable {
        var name: String, delay: Double, duration: Double, at: [Double], easing: [String]
        /// Second `t` as a place in the animation, 0–100.
        func place(_ t: Double) -> Double { duration > 0 ? (t - delay) / duration * 100 : 0 }
        func time(_ place: Double) -> Double { delay + duration * place / 100 }
    }

    /// A mark at a second of the video: its number, its second, and whether it's the user's move (orange).
    struct Mark: Equatable {
        var id: Int, time: Double, yours: Bool
    }

    /// The keyframe chosen and the one being dragged, and what the tab does with them.
    struct Keyframing {
        var chosen: (id: String, at: Double)?
        var drag: (id: String, from: Double, to: Double)?
        /// A keyframe moved (the element, from, to), chosen (the element, its place), and its menu.
        var onMove: ((String, Double, Double) -> Void)?
        var onChoose: ((String, Double) -> Void)?
        var menu: ((String, Double) -> NSMenu?)?
        /// The menu of the seam between two scenes (the one going out, the one coming in).
        var seamMenu: ((String, String) -> NSMenu?)?
    }

    /// Where two scenes meet under `p` on the scene lane (or overlap, with a transition), within a few points.
    func seam(at p: NSPoint) -> (out: Clip, in: Clip)? {
        guard laneRect(0).contains(p) else { return nil }
        let sorted = scenes.filter { !$0.id.isEmpty }.sorted { $0.start < $1.start }
        for (a, b) in zip(sorted, sorted.dropFirst())
        where p.x >= x(b.start) - 6 && p.x <= x(max(a.end, b.start)) + 6 {
            return (a, b)
        }
        return nil
    }

    /// `arrow.left.arrow.right` on a chip where a scene comes in by a transition.
    func drawSeams() {
        let row = laneRect(0), side = Metrics.countCapsule
        let sign = NSImage.symbol("arrow.left.arrow.right", size: Metrics.iconTiny)
            .withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor]))
        for scene in scenes where scene.transition != nil {
            let r = NSRect(x: x(scene.start) - 1, y: row.midY - side / 2, width: side, height: side)
            NSColor.controlBackgroundColor.setFill()
            let chip = NSBezierPath(roundedRect: r, xRadius: Metrics.radiusXS, yRadius: Metrics.radiusXS)
            chip.fill()
            NSColor.separatorColor.setStroke()
            chip.stroke()
            guard let sign else { continue }
            let at = NSRect(
                x: r.midX - sign.size.width / 2, y: r.midY - sign.size.height / 2, width: sign.size.width,
                height: sign.size.height)
            sign.draw(in: at, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    private func keyframes() -> [(id: String, keys: Keys, lane: Int)] {
        tracks.enumerated().compactMap { i, t in t.keys.map { (t.id, $0, i + 1) } }
    }

    private func diamondRect(_ keys: Keys, _ place: Double, lane: Int) -> NSRect {
        let row = laneRect(lane)
        return NSRect(x: x(keys.time(place)) - 5, y: row.midY - 5, width: 10, height: 10)
    }

    /// The keyframe under `p`: its element and place.
    func keyframe(at p: NSPoint) -> (id: String, at: Double)? {
        for (id, keys, lane) in keyframes() {
            if let at = keys.at.first(where: { diamondRect(keys, $0, lane: lane).insetBy(dx: -3, dy: -3).contains(p) })
            {
                return (id, at)
            }
        }
        return nil
    }

    func drawKeyframes() {
        for (id, keys, lane) in keyframes() {
            for place in keys.at {
                let dragged = keyframing.drag.map { $0.id == id && $0.from == place } ?? false
                let shown = dragged ? keyframing.drag?.to ?? place : place
                let chosen = keyframing.chosen.map { $0.id == id && $0.at == place } ?? false
                let r = diamondRect(keys, shown, lane: lane).insetBy(dx: 1, dy: 1)
                let shape = NSBezierPath()
                shape.move(to: NSPoint(x: r.midX, y: r.minY))
                shape.line(to: NSPoint(x: r.maxX, y: r.midY))
                shape.line(to: NSPoint(x: r.midX, y: r.maxY))
                shape.line(to: NSPoint(x: r.minX, y: r.midY))
                shape.close()
                (chosen || dragged ? NSColor.controlAccentColor : NSColor.labelColor).setFill()
                shape.fill()
            }
        }
    }

    func keyDown(at p: NSPoint) -> Bool {
        guard let hit = keyframe(at: p), let keys = tracks.first(where: { $0.id == hit.id })?.keys else { return false }
        keyframing.chosen = hit
        keyframing.onChoose?(hit.id, hit.at)
        seek(x(keys.time(hit.at)))
        if hit.at > 0, hit.at < 100 { keyframing.drag = (hit.id, hit.at, hit.at) }
        window?.makeFirstResponder(self)
        return true
    }

    func keyDragged(to p: NSPoint) -> Bool {
        guard let drag = keyframing.drag, let keys = tracks.first(where: { $0.id == drag.id })?.keys else {
            return false
        }
        let before = keys.at.filter { $0 < drag.from }.max() ?? 0,
            after = keys.at.filter { $0 > drag.from }.min() ?? 100
        keyframing.drag?.to = min(max((keys.place(seconds(p.x)) * 10).rounded() / 10, before + 0.5), after - 0.5)
        needsDisplay = true
        return true
    }

    func keyUp() -> Bool {
        guard let drag = keyframing.drag else { return false }
        keyframing.drag = nil
        if drag.to != drag.from {
            keyframing.chosen = (drag.id, drag.to)
            keyframing.onMove?(drag.id, drag.from, drag.to)
        }
        needsDisplay = true
        return true
    }
}
