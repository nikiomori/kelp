import AppKit
import DesignKit

/// The studio under a motion page, as a video editor has it: a row of controls (play, a frame back and forward, the
/// time and the frame, the size, Export Video) over the timeline (`MotionTimeline`). The page plays itself
/// (`MotionPage`) and tells the studio where it is (`show`); the controls call the page, and a scene moved or
/// trimmed on the timeline, or an element chosen, goes to the tab (`onClip`, `onChoose`).
@MainActor
final class MotionStudio {
    private(set) lazy var view: NSView = {
        timeline.onSeek = { [weak self] at in self?.act("window.kelpMotion?.seek(\(at))") }
        timeline.onClip = { [weak self] was, now, lane in self?.onClip?(was, now, lane) }
        timeline.onRemove = { [weak self] id in self?.onRemove?(id) }
        timeline.onMark = { [weak self] id in self?.act("window.kelpMarks?.reveal(\(id))") }
        timeline.onDuplicate = { [weak self] id in self?.onDuplicate?(id) }
        timeline.onChoose = { [weak self] id in
            self?.chose(id)
            self?.onChoose?(id)
        }
        export.toolTip = String(localized: "An MP4 of the whole page, frame by frame")
        let controls = Bar.content(
            [
                play,
                IconButton(.symbol("backward.frame"), tip: String(localized: "A Frame Back (←)")) { [weak self] in
                    self?.act("window.kelpMotion?.step(-1)")
                },
                IconButton(.symbol("forward.frame"), tip: String(localized: "A Frame Forward (→)")) { [weak self] in
                    self?.act("window.kelpMotion?.step(1)")
                },
                time, frame
            ], [size, export], stretching: frame)
        let line = NSBox()
        line.boxType = .separator
        return stacked(line, controls, timeline)
    }()
    private lazy var play = IconButton(.symbol("play.fill"), tip: String(localized: "Play (Space)")) {
        [weak self] in self?.act("window.kelpMotion?.toggle()")
    }
    private let time = NSTextField.label("", font: .uiDigits(TextSize.row))
    private let frame = NSTextField.label("", font: .uiDigits(TextSize.row), color: .secondaryLabelColor)
    private let size = NSTextField.label("", font: .uiDigits(TextSize.row), color: .secondaryLabelColor)
    private let timeline = MotionTimeline()
    private lazy var export = TextButton(String(localized: "Export Video…")) { [weak self] in self?.onExport?() }
    private let act: (String) -> Void
    var onExport: (() -> Void)?
    /// A clip moved or trimmed on the timeline: as it was, as it is now, and its lane (0 for the scenes).
    var onClip: ((MotionTimeline.Clip, MotionTimeline.Clip, Int) -> Void)?
    /// The time shown, kept so the page comes back to it when it's drawn again.
    private(set) var at = 0.0
    /// The page's scenes, as the timeline shows them.
    private(set) var scenes: [MotionTimeline.Clip] = []
    /// The frames a second the arrows step by and a video is made at.
    var fps = 30.0
    /// An element's block clicked on the timeline: its `data-id`, to choose on the stage.
    var onChoose: ((String) -> Void)?
    /// A clip taken out or copied on the timeline: its `data-id`.
    var onRemove: ((String) -> Void)?, onDuplicate: ((String) -> Void)?

    /// `act` runs a call on the page (`window.kelpMotion`).
    init(act: @escaping (String) -> Void) { self.act = act }

    /// Where the page is: its time and length in seconds, whether it plays, the stage's size, and the timeline's lanes.
    struct State {
        var at = 0.0, length = 0.0, playing = false, width = 1920, height = 1080
        var scenes: [MotionTimeline.Clip] = [], tracks: [MotionTimeline.Clip] = []
        var marks: [MotionTimeline.Mark] = []
    }

    func show(_ state: State) {
        _ = view
        at = state.at
        play.image = .symbol(state.playing ? "pause.fill" : "play.fill", state.playing ? "Pause" : "Play")
        time.stringValue = Self.clock(state.at) + " / " + Self.clock(state.length)
        frame.stringValue = String(
            localized: "frame \(Int((state.at * fps).rounded()) + 1) of \(Int((state.length * fps).rounded(.up)) + 1)")
        size.stringValue = "\(state.width) × \(state.height) · \(Int(fps)) fps"
        timeline.set(
            at: state.at, length: state.length, scenes: state.scenes, tracks: state.tracks, marks: state.marks)
        scenes = state.scenes
    }

    /// The element chosen on the page, whose lane stands out ("" for none).
    func chose(_ id: String) { timeline.chosen = id }

    /// While a video is made: which frame of how many, or nil when it's done.
    func exporting(_ frame: Int?, of frames: Int) {
        _ = view
        export.isEnabled = frame == nil
        export.title =
            frame.map { String(localized: "Exporting \($0 * 100 / max(frames, 1))%") }
            ?? String(localized: "Export Video…")
    }

    /// 3.2 seconds as `0:03.20`.
    static func clock(_ seconds: Double) -> String {
        let hundredths = Int((max(seconds, 0) * 100).rounded())
        return String(format: "%d:%02d.%02d", hundredths / 6000, hundredths / 100 % 60, hundredths % 100)
    }
}
