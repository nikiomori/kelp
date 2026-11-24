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
        /// An element hidden by hand (`data-hidden`): not in the page or the video.
        var hidden = false
        /// Its first animation's keyframes, when it has one; a scene's way in from the one before.
        var keys: Keys?, transition: String?
    }
    private enum Drag { case time, move(Clip, Double), start(Clip), end(Clip) }

    private(set) var at = 0.0, length = 1.0, scenes: [Clip] = [], marks: [Mark] = []
    /// The elements' lanes, the frontmost first, as layers.
    private(set) var tracks: [Clip] = []
    /// How far the lanes are scrolled down, and a lane being dragged to another place among the layers.
    var laneOffset: CGFloat = 0
    var laneDrag: (from: Int, to: Int)?
    /// The element lane under the pointer (1 and on), which shows its eye.
    var hoveredLane: Int?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) { pointerMoved(to: convert(event.locationInWindow, from: nil)) }

    override func mouseExited(with event: NSEvent) {
        hoveredLane = nil
        needsDisplay = true
    }
    /// An element hidden or shown again (its `data-id`), and the elements in their new order, the frontmost first.
    var onHide: ((String, Bool) -> Void)?, onRestack: (([String]) -> Void)?
    /// How close it looks: 1 shows the whole length, more shows `length / zoom` seconds from `from`.
    private(set) var zoom = 1.0
    var from = 0.0
    var span: Double { length / zoom }
    /// The zoom changed by a pinch or ⌘ and the wheel, for the studio's slider.
    var onZoom: ((Double) -> Void)?
    private var drag: Drag?
    /// The clip being dragged, as it is now, and its lane.
    var dragged: Clip?, draggedLane = 0
    /// The element chosen on the page: its lane stands out.
    var chosen = "" { didSet { if chosen != oldValue { needsDisplay = true } } }
    var onSeek: ((Double) -> Void)?
    /// A clip moved or trimmed: as it was, and as it is now. A scene is on lane 0.
    var onClip: ((Clip, Clip, Int) -> Void)?
    var onChoose: ((String) -> Void)?
    /// A clip cut, trimmed, copied or pasted (`split`, `trimStart`, `trimEnd`, `copy`, `cut`, `paste`): the kind, and
    /// the clip clicked last.
    var onCut: ((String, String?) -> Void)?
    /// A mark's diamond clicked: its number.
    var onMark: ((Int) -> Void)?
    /// A clip taken out (⌫) or copied (⌘D, or from its menu): its `data-id`, and whether to copy it.
    var onRemove: ((String) -> Void)?, onDuplicate: ((String) -> Void)?
    /// Files dropped from Finder: they join the page from the second they were dropped at (`onDropFiles`).
    var onDropFiles: (([URL], Double) -> Void)? {
        didSet { registerForDraggedTypes(onDropFiles == nil ? [] : [.fileURL]) }
    }
    /// The clip clicked last, which ⌫ and ⌘D act on.
    var picked: String?
    /// The clips taken together, and the box or the group's drag under way (`MotionTimeline+Select`).
    var selecting = Selecting(), keyframing = Keyframing()
    /// Clips moved together (as they were, as they are now), and several acted on at once (`remove`, `copy`, `cut`).
    var onGroup: (([(was: Clip, now: Clip)]) -> Void)?, onMany: ((String, [String]) -> Void)?

    /// A lane's height is a row's; the ruler is a little lower.
    static let ruler = Metrics.row - Metrics.gapTight, lane = Metrics.row, shown = 6
    /// The names' column: as wide as the longest name and its eye, from 120 to 180.
    private(set) var names: CGFloat = 120
    /// The lane of marks, above the scenes, while there are any.
    var marksLane: CGFloat { marks.isEmpty ? 0 : Self.lane }
    private var lanes: Int { rows.count }
    /// The subtitles' cues, a lane of their own under the elements' when there are any (`setCaptions`).
    var captions: [Clip] = []
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.ruler + Self.lane * CGFloat(2 + Self.shown) + Metrics.gap)
    }

    /// The work area, in and out in seconds: a band on the ruler, and what's outside it dimmed.
    var range: ClosedRange<Double>? { didSet { if range != oldValue { needsDisplay = true } } }

    func set(at: Double, length: Double, scenes: [Clip], tracks: [Clip], marks: [Mark] = []) {
        let length = max(length, 0.1)
        guard (at, length, scenes, tracks, marks) != (self.at, self.length, self.scenes, self.tracks, self.marks)
        else { return }
        (self.at, self.length, self.scenes, self.tracks, self.marks) = (at, length, scenes, tracks, marks)
        let widest =
            ([String(localized: "Scenes")] + tracks.map(\.title)).map {
                NSAttributedString(string: $0, attributes: [.font: NSFont.ui(TextSize.row)]).size().width
            }.max() ?? 0
        names = min(max(widest + Metrics.inset + Metrics.gapWide + 18 + Metrics.gap, 120), 180)
        // While it plays past what shows, the view turns the page.
        if at < from || at > from + span { from = at - span * 0.1 }
        from = min(max(from, 0), length - span)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Places

    var track: NSRect {
        NSRect(x: names, y: 0, width: max(bounds.width - names - Metrics.inset, 1), height: bounds.height)
    }
    func x(_ seconds: Double) -> CGFloat { track.minX + track.width * CGFloat((seconds - from) / span) }
    func seconds(_ x: CGFloat) -> Double { from + Double((x - track.minX) / track.width) * span }

    /// Zooms to `zoom` (1 to 40), keeping second `around` (the time, when nil) where it is.
    func setZoom(_ zoom: Double, around: Double? = nil) {
        let anchor = around ?? at, place = (anchor - from) / span
        self.zoom = min(max(zoom, 1), 40)
        from = min(max(anchor - place * span, 0), length - span)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        onZoom?(self.zoom)
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), around: seconds(convert(event.locationInWindow, from: nil).x))
    }

    /// ⌘ and the wheel zoom; a sideways scroll moves along while zoomed in.
    override func scrollWheel(with event: NSEvent) {
        let pointer = seconds(convert(event.locationInWindow, from: nil).x)
        if event.modifierFlags.contains(.command) {
            return setZoom(zoom * (1 + event.scrollingDeltaY * 0.01), around: pointer)
        }
        let sideways = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : 0
        if sideways == 0, scrollLanes(by: event.scrollingDeltaY) { return }
        guard zoom > 1, sideways != 0 else { return super.scrollWheel(with: event) }
        from = min(max(from - Double(sideways / track.width) * span, 0), length - span)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
    func laneRect(_ index: Int) -> NSRect {
        NSRect(
            x: 0, y: Self.ruler + marksLane + Self.lane * CGFloat(index) - laneOffset, width: bounds.width,
            height: Self.lane)
    }
    /// Where mark `m`'s diamond is.
    func diamond(_ m: Mark) -> NSRect {
        NSRect(x: x(m.time) - 6, y: Self.ruler + Self.lane / 2 - 6, width: 12, height: 12)
    }
    func box(_ clip: Clip, lane: Int) -> NSRect {
        let row = laneRect(lane).insetBy(dx: 0, dy: 3)
        return NSRect(x: x(clip.start), y: row.minY, width: max(x(clip.end) - x(clip.start), 4), height: row.height)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.ui(TextSize.caption), nameFont = NSFont.ui(TextSize.row)
        let laneNames =
            [String(localized: "Scenes")] + tracks.map(\.title)
            + (captions.isEmpty ? [] : [String(localized: "Subtitles")])
        NSGraphicsContext.saveGraphicsState()
        lanesArea.clip()
        for (i, name) in laneNames.enumerated() {
            let row = laneRect(i)
            if i % 2 == 1 {
                NSColor.fillRest.setFill()
                row.fill()
            }
            let element = i > 0 && i <= tracks.count, hidden = element && tracks[i - 1].hidden
            text(
                name, at: NSPoint(x: Metrics.inset, y: row.midY), font: nameFont,
                color: hidden ? .tertiaryLabelColor : .secondaryLabelColor, width: nameWidth - (element ? 18 : 0))
            if element, hidden || i == hoveredLane { drawEye(lane: i, hidden: hidden) }
        }
        drawLaneDrag()
        NSGraphicsContext.restoreGraphicsState()
        if !marks.isEmpty {
            text(
                String(localized: "Marks"), at: NSPoint(x: Metrics.inset, y: Self.ruler + Self.lane / 2),
                font: nameFont,
                color: .secondaryLabelColor, width: nameWidth)
        }
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: Self.ruler - 0.5, width: bounds.width, height: 0.5).fill()
        // What moves with the time stays right of the names, however far it's zoomed.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: track.minX - 6, y: 0, width: bounds.width, height: bounds.height)).addClip()
        drawRuler()
        drawClips(font)
        drawSelecting()
        drawKeyframes()
        drawSeams()
        if let range {
            NSColor.systemYellow.setFill()
            NSRect(
                x: x(range.lowerBound), y: Self.ruler - 4, width: x(range.upperBound) - x(range.lowerBound), height: 3
            )
            .fill()
            NSColor.outside.setFill()
            let lanesTop = Self.ruler, lanesBottom = Self.ruler + marksLane + Self.lane * CGFloat(lanes)
            NSRect(x: track.minX, y: lanesTop, width: x(range.lowerBound) - track.minX, height: lanesBottom - lanesTop)
                .fill()
            NSRect(
                x: x(range.upperBound), y: lanesTop, width: track.maxX - x(range.upperBound),
                height: lanesBottom - lanesTop
            ).fill()
        }
        let head = x(at)
        NSColor.controlAccentColor.setFill()
        NSRect(x: head - 1, y: 0, width: 2, height: Self.ruler + marksLane + Self.lane * CGFloat(lanes)).fill()
        NSBezierPath(ovalIn: NSRect(x: head - 5, y: Self.ruler - 10, width: 10, height: 10)).fill()
        if let dragged {
            let label = String(format: "%.1f s · %.1f s", dragged.start, dragged.length)
            let rect = box(dragged, lane: draggedLane)
            text(label, at: NSPoint(x: rect.minX, y: rect.maxY + 9), font: font, color: .labelColor, width: 200)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private var nameWidth: CGFloat { names - Metrics.inset - Metrics.gap }
    /// Where the lanes are, under the ruler and the marks.
    var lanesArea: NSRect {
        NSRect(x: 0, y: Self.ruler + marksLane, width: bounds.width, height: bounds.height - Self.ruler - marksLane)
    }

    private func drawClips(_ font: NSFont) {
        for m in marks {
            let shape = NSBezierPath()
            let r = diamond(m).insetBy(dx: 1, dy: 1)
            shape.move(to: NSPoint(x: r.midX, y: r.minY))
            shape.line(to: NSPoint(x: r.maxX, y: r.midY))
            shape.line(to: NSPoint(x: r.midX, y: r.maxY))
            shape.line(to: NSPoint(x: r.minX, y: r.midY))
            shape.close()
            (m.yours ? NSColor.systemOrange : NSColor.tertiaryLabelColor).setFill()
            shape.fill()
        }
        NSGraphicsContext.saveGraphicsState()
        lanesArea.clip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        for scene in scenes {
            let clip = shown(draggedLane == 0 && dragged?.id == scene.id ? dragged ?? scene : scene)
            draw(
                clip, in: box(clip, lane: 0), fill: .fillRest,
                chosen: (draggedLane == 0 && dragged?.id == scene.id) || selecting.ids.contains(scene.id), font: font)
        }
        for (i, track) in tracks.enumerated() {
            let mine = shown(draggedLane == i + 1 ? dragged ?? track : track)
            draw(
                mine, in: box(mine, lane: i + 1), fill: .fillSelected,
                chosen: draggedLane == i + 1
                    || (!track.id.isEmpty && (track.id == chosen || selecting.ids.contains(track.id))),
                font: font)
        }
        drawCaptions(font)
    }

    // MARK: The pointer

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let m = marks.first(where: { diamond($0).insetBy(dx: -3, dy: -3).contains(p) }) {
            at = m.time
            needsDisplay = true
            onSeek?(m.time)
            onMark?(m.id)
            return
        }
        if layerDown(at: p) || keyDown(at: p) || selectDown(at: p, shift: event.modifierFlags.contains(.shift)) {
            return
        }
        let lanes = rows
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
        let p = convert(event.locationInWindow, from: nil)
        if layerDragged(to: p) || keyDragged(to: p) || selectDragged(to: p) { return }
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
        if layerUp() || keyUp() || selectUp() { return }
        if selecting.box == nil, drag == nil, convert(event.locationInWindow, from: nil).x >= track.minX {
            seek(convert(event.locationInWindow, from: nil).x)
        }
        let lanes = rows
        if let dragged, let before = lanes[draggedLane].first(where: { $0.id == dragged.id }), dragged != before {
            if draggedLane == 0, let i = scenes.firstIndex(where: { $0.id == dragged.id }) { scenes[i] = dragged }
            if draggedLane > 0, draggedLane <= tracks.count { tracks[draggedLane - 1] = dragged }
            if let i = captions.firstIndex(where: { $0.id == dragged.id }) { captions[i] = dragged }
            onClip?(before, dragged, draggedLane)
        }
        drag = nil
        dragged = nil
        draggedLane = 0
        needsDisplay = true
    }

    func seek(_ x: CGFloat) {
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
