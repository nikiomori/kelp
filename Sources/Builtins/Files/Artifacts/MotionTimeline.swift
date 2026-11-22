import AppKit
import DesignKit

/// A motion page's timeline: a ruler in seconds, the scenes on the first lane and each element that moves on a lane of
/// its own, with the lanes' names on the left and a line where the time is. A click or a drag on the ruler or an empty
/// spot moves the time. A scene's block moves when dragged and trims by its edges, in tenths of a second, snapping to
/// the time and to the other scenes' edges. An element's block does the same (its edges only when it has one
/// animation), and a click on it chooses the element on the page. What a block becomes goes to `onClip` when the drag
/// ends.
@MainActor
final class MotionTimeline: NSView {
    struct Clip: Equatable {
        var id: String, title: String, start: Double, length: Double
        /// An element's animations: when each starts and how long it runs. A scene has none.
        var delays: [Double] = [], lengths: [Double] = []
        var end: Double { start + length }
        /// Whether its edges trim it: a scene, or an element with one animation.
        var trims: Bool { delays.count <= 1 }
    }
    private enum Drag { case time, move(Clip, Double), start(Clip), end(Clip) }

    private var at = 0.0, length = 1.0, scenes: [Clip] = [], tracks: [Clip] = []
    private var drag: Drag?
    /// The clip being dragged, as it is now, and its lane.
    private var dragged: Clip?, draggedLane = 0
    /// The element chosen on the page: its lane stands out.
    var chosen = "" { didSet { if chosen != oldValue { needsDisplay = true } } }
    var onSeek: ((Double) -> Void)?
    /// A clip moved or trimmed: as it was, and as it is now. A scene is on lane 0.
    var onClip: ((Clip, Clip, Int) -> Void)?
    var onChoose: ((String) -> Void)?
    /// A clip taken out (⌫) or copied (⌘D, or from its menu): its `data-id`, and whether to copy it.
    var onRemove: ((String) -> Void)?, onDuplicate: ((String) -> Void)?
    /// The clip clicked last, which ⌫ and ⌘D act on.
    private var picked: String?

    private static let names: CGFloat = 112, ruler: CGFloat = 20, lane: CGFloat = 24, most = 6
    private var lanes: Int { 1 + min(tracks.count, Self.most) }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.ruler + Self.lane * CGFloat(1 + Self.most) + Metrics.gap)
    }

    func set(at: Double, length: Double, scenes: [Clip], tracks: [Clip]) {
        let length = max(length, 0.1)
        guard (at, length, scenes, tracks) != (self.at, self.length, self.scenes, self.tracks) else { return }
        (self.at, self.length, self.scenes, self.tracks) = (at, length, scenes, tracks)
        needsDisplay = true
    }

    // MARK: Places

    private var track: NSRect {
        NSRect(x: Self.names, y: 0, width: max(bounds.width - Self.names - Metrics.inset, 1), height: bounds.height)
    }
    private func x(_ seconds: Double) -> CGFloat { track.minX + track.width * CGFloat(seconds / length) }
    private func seconds(_ x: CGFloat) -> Double { Double((x - track.minX) / track.width) * length }
    private func laneRect(_ index: Int) -> NSRect {
        NSRect(x: 0, y: Self.ruler + Self.lane * CGFloat(index), width: bounds.width, height: Self.lane)
    }
    private func box(_ clip: Clip, lane: Int) -> NSRect {
        let row = laneRect(lane).insetBy(dx: 0, dy: 3)
        return NSRect(x: x(clip.start), y: row.minY, width: max(x(clip.end) - x(clip.start), 4), height: row.height)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawRuler()
        let font = NSFont.ui(TextSize.caption)
        let laneNames = [String(localized: "Scenes")] + tracks.prefix(Self.most).map(\.title)
        for (i, name) in laneNames.enumerated() {
            let row = laneRect(i)
            if i % 2 == 1 {
                NSColor.fillRest.setFill()
                row.fill()
            }
            text(
                name, at: NSPoint(x: Metrics.inset, y: row.midY), font: font, color: .secondaryLabelColor,
                width: Self.names - Metrics.inset - Metrics.gap)
        }
        for scene in scenes {
            let clip = draggedLane == 0 && dragged?.id == scene.id ? dragged ?? scene : scene
            draw(
                clip, in: box(clip, lane: 0), fill: NSColor.fillTint(.controlAccentColor),
                chosen: draggedLane == 0 && dragged?.id == scene.id, font: font)
        }
        for (i, track) in tracks.prefix(Self.most).enumerated() {
            let mine = draggedLane == i + 1 ? dragged ?? track : track
            draw(
                mine, in: box(mine, lane: i + 1), fill: .fillSelected,
                chosen: draggedLane == i + 1 || (!track.id.isEmpty && track.id == chosen), font: font)
        }
        let head = x(at)
        NSColor.controlAccentColor.setFill()
        NSRect(x: head - 1, y: 0, width: 2, height: Self.ruler + Self.lane * CGFloat(lanes)).fill()
        NSBezierPath(ovalIn: NSRect(x: head - 5, y: Self.ruler - 10, width: 10, height: 10)).fill()
        if let dragged {
            let label = String(format: "%.1f s · %.1f s", dragged.start, dragged.length)
            let rect = box(dragged, lane: draggedLane)
            text(label, at: NSPoint(x: rect.minX, y: rect.maxY + 9), font: font, color: .labelColor, width: 200)
        }
    }

    private func drawRuler() {
        let font = NSFont.uiDigits(TextSize.caption)
        let step = [0.5, 1, 2, 5, 10, 30].first { CGFloat($0 / length) * track.width >= 48 } ?? 60
        var mark = 0.0
        while mark <= length + 0.001 {
            NSColor.separatorColor.setFill()
            NSRect(x: x(mark), y: Self.ruler - 6, width: 1, height: 6).fill()
            text(
                Self.label(mark), at: NSPoint(x: x(mark) + 3, y: Self.ruler / 2 - 2), font: font,
                color: .secondaryLabelColor, width: 60)
            mark += step
        }
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: Self.ruler - 0.5, width: bounds.width, height: 0.5).fill()
    }

    private func draw(_ clip: Clip, in rect: NSRect, fill: NSColor, chosen: Bool, font: NSFont) {
        fill.setFill()
        let shape = NSBezierPath(roundedRect: rect, xRadius: Metrics.gapTight, yRadius: Metrics.gapTight)
        shape.fill()
        if chosen || fill != .fillSelected {   // a scene, or the clip chosen
            NSColor.controlAccentColor.setStroke()
            shape.lineWidth = chosen ? 2 : 1
            shape.stroke()
        }
        if rect.width > 30 {
            text(
                clip.title, at: NSPoint(x: rect.minX + Metrics.gapTight + 2, y: rect.midY), font: font,
                color: .labelColor, width: rect.width - 2 * Metrics.gapTight)
        }
    }

    private func text(_ string: String, at point: NSPoint, font: NSFont, color: NSColor, width: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let made = NSAttributedString(
            string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        let height = made.size().height
        made.draw(in: NSRect(x: point.x, y: point.y - height / 2, width: width, height: height))
    }

    static func label(_ seconds: Double) -> String {
        seconds.rounded() == seconds ? "\(Int(seconds))s" : String(format: "%.1fs", seconds)
    }

    // MARK: The pointer

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let lanes = [scenes] + tracks.prefix(Self.most).map { [$0] }
        for (lane, clips) in lanes.enumerated() {
            guard let clip = clips.first(where: { box($0, lane: lane).insetBy(dx: -3, dy: 0).contains(p) }) else {
                continue
            }
            if lane > 0 { onChoose?(clip.id) }
            guard !clip.id.isEmpty else { return }
            picked = clip.id
            window?.makeFirstResponder(self)
            let rect = box(clip, lane: lane)
            let edge = clip.trims ? 6.0 : 0
            drag =
                p.x < rect.minX + edge ? .start(clip) : p.x > rect.maxX - edge ? .end(clip) : .move(clip, seconds(p.x))
            (dragged, draggedLane) = (clip, lane)
            return
        }
        if p.x >= track.minX {
            drag = .time
            seek(p.x)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let now = seconds(convert(event.locationInWindow, from: nil).x)
        switch drag {
        case .time: seek(convert(event.locationInWindow, from: nil).x)
        case .move(let clip, let from):
            dragged?.start = snap(min(max(clip.start + now - from, 0), length - 0.1), clip.id)
        case .start(let clip):
            let start = snap(min(max(now, 0), clip.end - 0.1), clip.id)
            dragged?.start = start
            dragged?.length = clip.end - start
        case .end(let clip):
            dragged?.length = max(snap(min(now, length), clip.id) - clip.start, 0.1)
        case nil: return
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let lanes = [scenes] + tracks.prefix(Self.most).map { [$0] }
        if let dragged, let before = lanes[draggedLane].first(where: { $0.id == dragged.id }), dragged != before {
            if draggedLane == 0, let i = scenes.firstIndex(where: { $0.id == dragged.id }) { scenes[i] = dragged }
            if draggedLane > 0 { tracks[draggedLane - 1] = dragged }
            onClip?(before, dragged, draggedLane)
        }
        drag = nil
        dragged = nil
        draggedLane = 0
        needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let picked, [51, 117].contains(event.keyCode) else { return super.keyDown(with: event) }   // ⌫, ⌦
        onRemove?(picked)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let picked, event.modifierFlags.contains(.command),
            event.charactersIgnoringModifiers == "d"
        else { return super.performKeyEquivalent(with: event) }
        onDuplicate?(picked)
        return true
    }

    /// A clip's menu: Duplicate and Delete.
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let lanes = [scenes] + tracks.prefix(Self.most).map { [$0] }
        for (lane, clips) in lanes.enumerated() {
            guard let clip = clips.first(where: { box($0, lane: lane).contains(p) }), !clip.id.isEmpty else { continue }
            picked = clip.id
            let menu = NSMenu()
            menu.add(String(localized: "Duplicate"), key: "d") { [weak self] in self?.onDuplicate?(clip.id) }
            menu.addItem(.separator())
            menu.add(String(localized: "Delete")) { [weak self] in self?.onRemove?(clip.id) }
            return menu
        }
        return nil
    }

    override func resetCursorRects() {
        let lanes = [scenes] + tracks.prefix(Self.most).map { [$0] }
        for (lane, clips) in lanes.enumerated() {
            for clip in clips where !clip.id.isEmpty && clip.trims { edges(box(clip, lane: lane)) }
        }
    }

    private func edges(_ rect: NSRect) {
        addCursorRect(NSRect(x: rect.minX - 3, y: rect.minY, width: 6, height: rect.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: rect.maxX - 3, y: rect.minY, width: 6, height: rect.height), cursor: .resizeLeftRight)
    }

    private func seek(_ x: CGFloat) {
        at = min(max(seconds(x), 0), length)
        needsDisplay = true
        onSeek?(at)
    }

    /// `seconds` in tenths, or the time or another scene's edge when one is within 6 points of it.
    private func snap(_ seconds: Double, _ id: String) -> Double {
        let edges = [at] + scenes.filter { $0.id != id }.flatMap { [$0.start, $0.end] }
        if let near = edges.min(by: { abs($0 - seconds) < abs($1 - seconds) }), abs(x(near) - x(seconds)) < 6 {
            return near
        }
        return (seconds * 10).rounded() / 10
    }
}
