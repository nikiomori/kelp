import AppKit
import DesignKit

/// The timeline's ruler, its clips and their words.
extension MotionTimeline {
    func drawRuler() {
        let font = NSFont.uiDigits(TextSize.caption)
        let step = [0.1, 0.2, 0.5, 1, 2, 5, 10, 30].first { CGFloat($0 / span) * track.width >= 48 } ?? 60
        var mark = (from / step).rounded(.down) * step
        while mark <= min(from + span, length) + 0.001 {
            NSColor.separatorColor.setFill()
            NSRect(x: x(mark), y: Self.ruler - 6, width: 1, height: 6).fill()
            text(
                Self.label(mark), at: NSPoint(x: x(mark) + 3, y: Self.ruler / 2 - 2), font: font,
                color: .secondaryLabelColor, width: 60)
            mark += step
        }
    }

    func draw(_ clip: Clip, in rect: NSRect, fill: NSColor, chosen: Bool, font: NSFont) {
        fill.setFill()
        let shape = NSBezierPath(roundedRect: rect, xRadius: Metrics.radiusXS, yRadius: Metrics.radiusXS)
        shape.fill()
        // A scene has a hairline round it; the accent marks only the clip chosen or dragged.
        if chosen || fill == .fillRest {
            (chosen ? NSColor.controlAccentColor : .separatorColor).setStroke()
            shape.lineWidth = chosen ? 2 : 1
            shape.stroke()
        }
        if let wave = clip.wave, !wave.isEmpty {
            NSColor.tertiaryLabelColor.setFill()   // a sound’s bars, under its name: grey, as colour says a state
            let bar = rect.width / CGFloat(wave.count)
            for (i, level) in wave.enumerated() {
                let h = max(1, CGFloat(level) * (rect.height - 4))
                NSRect(x: rect.minX + CGFloat(i) * bar, y: rect.midY - h / 2, width: max(1, bar - 1), height: h).fill()
            }
        }
        if rect.width > 30 {
            text(
                clip.title, at: NSPoint(x: rect.minX + Metrics.gapTight + 2, y: rect.midY), font: font,
                color: .labelColor, width: rect.width - 2 * Metrics.gapTight)
        }
    }

    func text(_ string: String, at point: NSPoint, font: NSFont, color: NSColor, width: CGFloat) {
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

    /// Each lane's clips: the scenes, an element each, and the subtitles' cues when there are any.
    var rows: [[Clip]] { [scenes] + tracks.map { [$0] } + (captions.isEmpty ? [] : [captions]) }

    func setCaptions(_ cues: [Clip]) {
        guard cues != captions else { return }
        captions = cues
        needsDisplay = true
    }

    /// The subtitles' lane, its cues like a scene's clips.
    func drawCaptions(_ font: NSFont) {
        guard !captions.isEmpty else { return }
        let lane = tracks.count + 1
        for cue in captions {
            let clip = shown(draggedLane == lane && dragged?.id == cue.id ? dragged ?? cue : cue)
            draw(
                clip, in: box(clip, lane: lane), fill: .fillRest, chosen: draggedLane == lane && dragged?.id == cue.id,
                font: font)
        }
    }

    /// The music's beats: a thin grey line down the lanes at each, which clips snap to.
    func drawBeats() {
        guard !beats.isEmpty else { return }
        NSColor.tertiaryLabelColor.setFill()
        let area = lanesArea
        for beat in beats where beat >= from && beat <= from + span {
            NSRect(x: x(beat), y: area.minY, width: 1, height: area.height).fill(using: .sourceOver)
        }
    }
}
