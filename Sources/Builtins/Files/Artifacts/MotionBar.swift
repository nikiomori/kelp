import AppKit
import DesignKit

/// The bar under a motion page's own bar: play and pause, the time, the timeline with the page's scenes (a click or a
/// drag moves the time), a frame back and forward, and Export Video. The page plays itself (`MotionPage`) and tells
/// the bar where it is (`show`); the bar's controls call the page.
@MainActor
final class MotionBar {
    private(set) lazy var bar: Bar = {
        timeline.onSeek = { [weak self] at in self?.act("window.kelpMotion?.seek(\(at))") }
        export.toolTip = String(localized: "An MP4 of the whole page, frame by frame")
        let made = Bar.content(
            [play, time, timeline],
            [
                IconButton(.symbol("chevron.left"), tip: String(localized: "A Frame Back")) { [weak self] in
                    self?.act("window.kelpMotion?.step(-1)")
                },
                IconButton(.symbol("chevron.right"), tip: String(localized: "A Frame Forward")) { [weak self] in
                    self?.act("window.kelpMotion?.step(1)")
                },
                export
            ], stretching: timeline)
        return made
    }()
    private lazy var play = IconButton(.symbol("play.fill"), tip: String(localized: "Play (Space)")) {
        [weak self] in self?.act("window.kelpMotion?.toggle()")
    }
    private let time = NSTextField.label("", font: .uiDigits(TextSize.row), color: .secondaryLabelColor)
    private let timeline = MotionTimeline()
    private lazy var export = TextButton(String(localized: "Export Video…")) { [weak self] in self?.onExport?() }
    private let act: (String) -> Void
    var onExport: (() -> Void)?

    /// `act` runs a call on the page (`window.kelpMotion`).
    init(act: @escaping (String) -> Void) { self.act = act }

    /// Shows the time `at` of `length` seconds, whether it plays, and the page's scenes.
    func show(at: Double, length: Double, playing: Bool, scenes: [MotionTimeline.Scene]) {
        _ = bar
        play.image = .symbol(playing ? "pause.fill" : "play.fill", playing ? "Pause" : "Play")
        time.stringValue = Self.clock(at) + " / " + Self.clock(length)
        timeline.set(at: at, length: length, scenes: scenes)
    }

    /// While a video is made: which frame of how many, or nil when it's done.
    func exporting(_ frame: Int?, of frames: Int) {
        _ = bar
        export.isEnabled = frame == nil
        export.title =
            frame.map { String(localized: "Exporting \($0 * 100 / max(frames, 1))%") }
            ?? String(localized: "Export Video…")
    }

    /// 3.2 seconds as `0:03.2`.
    static func clock(_ seconds: Double) -> String {
        let tenths = Int((max(seconds, 0) * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
    }
}

/// The timeline in a motion page's bar: its scenes as blocks along the length, and a line where the time is. A click or
/// a drag moves the time.
@MainActor
final class MotionTimeline: NSView {
    struct Scene: Equatable {
        var title: String, start: Double, duration: Double
    }
    private var at = 0.0, length = 1.0, scenes: [Scene] = []
    var onSeek: ((Double) -> Void)?

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Metrics.row) }

    func set(at: Double, length: Double, scenes: [Scene]) {
        guard (at, length, scenes) != (self.at, self.length, self.scenes) else { return }
        self.at = at
        self.length = max(length, 0.1)
        self.scenes = scenes
        needsDisplay = true
    }

    private func x(_ seconds: Double) -> CGFloat { bounds.minX + bounds.width * CGFloat(seconds / length) }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds.insetBy(dx: 0, dy: Metrics.gapTight)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: Metrics.gapTight, yRadius: Metrics.gapTight).fill()
        let font = NSFont.ui(TextSize.caption)
        for scene in scenes {
            let end = scene.duration > 0 ? scene.start + scene.duration : length
            let block = NSRect(x: x(scene.start), y: track.minY, width: x(end) - x(scene.start), height: track.height)
                .insetBy(dx: 1, dy: 2)
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: block, xRadius: Metrics.gapTight, yRadius: Metrics.gapTight).fill()
            let title = NSAttributedString(
                string: scene.title, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            let size = title.size()
            if size.width + 2 * Metrics.gapTight < block.width {
                title.draw(at: NSPoint(x: block.minX + Metrics.gapTight, y: block.midY - size.height / 2))
            }
        }
        NSColor.controlAccentColor.setFill()
        NSRect(x: x(at) - 1, y: bounds.minY, width: 2, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) { seek(event) }
    override func mouseDragged(with event: NSEvent) { seek(event) }

    private func seek(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let seconds = Double(max(0, min(p.x - bounds.minX, bounds.width)) / max(bounds.width, 1)) * length
        at = seconds
        needsDisplay = true
        onSeek?(seconds)
    }
}
