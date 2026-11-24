import AppKit
import Core
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
        timeline.onCut = { [weak self] kind, id in self?.onCut?(kind, id) }
        timeline.onGroup = { [weak self] moves in self?.onGroup?(moves) }
        timeline.onMany = { [weak self] kind, ids in self?.onMany?(kind, ids) }
        timeline.onDropFiles = { [weak self] files, at in self?.onDropFiles?(files, at) }
        timeline.onHide = { [weak self] id, hide in self?.onHide?(id, hide) }
        timeline.onRestack = { [weak self] ids in self?.onRestack?(ids) }
        timeline.onMark = { [weak self] id in self?.act("window.kelpMarks?.reveal(\(id))") }
        timeline.onDuplicate = { [weak self] id in self?.onDuplicate?(id) }
        timeline.onChoose = { [weak self] id in
            self?.chose(id)
            self?.onChoose?(id)
        }
        export.toolTip = String(localized: "An MP4 or a GIF of the whole page, frame by frame")
        let controls = Bar.content(
            [
                play,
                IconButton(.symbol("backward.frame"), tip: String(localized: "A Frame Back (←)")) { [weak self] in
                    self?.act("window.kelpMotion?.step(-1)")
                },
                IconButton(.symbol("forward.frame"), tip: String(localized: "A Frame Forward (→)")) { [weak self] in
                    self?.act("window.kelpMotion?.step(1)")
                },
                loop, speed, time, frame, rangeChip, whole,
                IconButton(.symbol("diamond"), tip: String(localized: "Keyframe at the Time (K)")) { [weak self] in
                    self?.onKeyframe?()
                },
                IconButton(.symbol("scissors"), tip: String(localized: "Split at the Time (S)")) { [weak self] in
                    self?.cut("split")
                },
                IconButton(.symbol("arrow.left.to.line"), tip: String(localized: "Trim the Start to the Time")) {
                    [weak self] in self?.cut("trimStart")
                },
                IconButton(.symbol("arrow.right.to.line"), tip: String(localized: "Trim the End to the Time")) {
                    [weak self] in self?.cut("trimEnd")
                }
            ],
            [
                zoomSlider, TextButton(String(localized: "Fit")) { [weak self] in self?.timeline.setZoom(1) }, size,
                export
            ], stretching: frame)
        speed.toolTip = String(localized: "How fast it plays")
        zoomSlider.toolTip = String(localized: "How close the timeline looks (or pinch, or ⌘ and scroll)")
        for rate in Self.rates { speed.addItem(withTitle: Self.rate(rate)) }
        speed.selectItem(withTitle: Self.rate(1))
        speed.font = .uiDigits(TextSize.row)
        speed.target = self
        speed.action = #selector(speedChosen)
        size.font = .uiDigits(TextSize.row)
        size.target = self
        size.action = #selector(formatChosen)
        size.toolTip = String(localized: "The stage’s shape")
        zoomSlider.controlSize = .small
        zoomSlider.target = self
        zoomSlider.action = #selector(zoomSlid)
        zoomSlider.widthAnchor.constraint(equalToConstant: 80).isActive = true
        timeline.onZoom = { [weak self] z in self?.zoomSlider.doubleValue = log2(z) }
        let line = NSBox()
        line.boxType = .separator
        return stacked(line, controls, timeline)
    }()
    private lazy var play = IconButton(.symbol("play.fill"), tip: String(localized: "Play (Space)")) {
        [weak self] in self?.act("window.kelpMotion?.toggle()")
    }
    private lazy var loop = IconButton(.symbol("repeat"), tip: String(localized: "Play Again at the End")) {
        [weak self] in self?.toggleLoop()
    }
    /// The work area set with I and O; a click takes it away.
    private lazy var rangeChip: TextButton = {
        let chip = TextButton("") { [weak self] in self?.act("window.kelpMotion?.setRange(null)") }
        chip.toolTip = String(localized: "The work area: I and O set it, a click here takes it away")
        chip.isHidden = true
        return chip
    }()
    /// Mark's mark on the whole video, with no second: for its pace, its music, its mood.
    private lazy var whole: TextButton = {
        let button = TextButton(String(localized: "+ To the Whole Video")) { [weak self] in
            self?.act("window.kelpMarks?.add({ kind: 'area', whole: true })")
        }
        button.toolTip = String(localized: "A mark about the whole video, not one moment of it")
        button.isHidden = true
        return button
    }()
    /// Whether Mark is on: its button for the whole video shows.
    var marking = false {
        didSet { whole.isHidden = !marking }
    }
    private let speed = PointerPopUpButton()
    /// The zoom as a power of two: 0 shows the whole length, 5 a thirty-second of it.
    private let zoomSlider = NSSlider(value: 0, minValue: 0, maxValue: log2(40), target: nil, action: nil)
    private var looping = false
    private let time = NSTextField.label("", font: .uiDigits(TextSize.row))
    private let frame = NSTextField.label("", font: .uiDigits(TextSize.caption), color: .secondaryLabelColor)
    private let size = PointerPopUpButton()
    private var stage = (width: 1920, height: 1080)
    private let timeline = MotionTimeline()
    private lazy var export = TextButton(String(localized: "Export Video…")) { [weak self] in self?.chooseExport() }
    /// How the last video was made, offered again.
    private(set) var exportOptions = MotionExport()
    private var exportPopover: MotionExportPopover?
    /// How fast it plays (1 is as it is), for the sounds Kelp plays beside it.
    private(set) var playbackRate = 1.0
    /// The videos made from this page, newest first (`MotionExports`).
    var exports: [MotionExports.Item] = []
    private let act: (String) -> Void
    var onExport: ((MotionExport) -> Void)?
    /// A clip moved or trimmed on the timeline: as it was, as it is now, and its lane (0 for the scenes).
    var onClip: ((MotionTimeline.Clip, MotionTimeline.Clip, Int) -> Void)?
    /// The time shown, kept so the page comes back to it when it's drawn again.
    private(set) var at = 0.0
    /// The page's scenes, as the timeline shows them.
    private(set) var scenes: [MotionTimeline.Clip] = []
    /// The page's elements' lanes, as the timeline shows them.
    private(set) var tracks: [MotionTimeline.Clip] = []
    /// The frames a second the arrows step by and a video is made at.
    var fps = 30.0
    /// An element's block clicked on the timeline: its `data-id`, to choose on the stage.
    var onChoose: ((String) -> Void)?
    /// Files dropped on the timeline, and the second they were dropped at.
    var onDropFiles: (([URL], Double) -> Void)?
    /// A clip cut, trimmed, copied or pasted: the kind, and the clip clicked last on the timeline.
    var onCut: ((String, String?) -> Void)?
    /// K, or ◆: a keyframe at the time.
    var onKeyframe: (() -> Void)?
    /// The lane clicked last on the timeline.
    var picked: String? { timeline.picked }
    /// What the timeline's keyframes do (moved, chosen, their menu).
    func keyframes(_ set: (inout MotionTimeline.Keyframing) -> Void) { set(&timeline.keyframing) }
    /// Clips moved together on the timeline, and several acted on at once (`remove`, `copy`, `cut`).
    var onGroup: (([(was: MotionTimeline.Clip, now: MotionTimeline.Clip)]) -> Void)?
    var onMany: ((String, [String]) -> Void)?

    private func cut(_ kind: String) { onCut?(kind, timeline.picked) }

    /// A shape chosen for the stage: its width and height in pixels.
    var onFormat: ((Int, Int) -> Void)?
    /// An element hidden or shown on the timeline, and the elements restacked there, the frontmost first.
    var onHide: ((String, Bool) -> Void)?, onRestack: (([String]) -> Void)?
    /// A clip taken out or copied on the timeline: its `data-id`.
    var onRemove: ((String) -> Void)?, onDuplicate: ((String) -> Void)?

    /// `act` runs a call on the page (`window.kelpMotion`).
    init(act: @escaping (String) -> Void) { self.act = act }

    /// Where the page is: its time and length in seconds, whether it plays, the stage's size, and the timeline's lanes.
    struct State {
        var at = 0.0, length = 0.0, playing = false, width = 1920, height = 1080
        var scenes: [MotionTimeline.Clip] = [], tracks: [MotionTimeline.Clip] = []
        var marks: [MotionTimeline.Mark] = []
        var range: ClosedRange<Double>?
        var captions: [MotionTimeline.Clip] = []
    }

    func show(_ state: State) {
        _ = view
        at = state.at
        play.image = .symbol(state.playing ? "pause.fill" : "play.fill", state.playing ? "Pause" : "Play")
        time.stringValue = Self.clock(state.at) + " / " + Self.clock(state.length)
        frame.stringValue = String(
            localized: "frame \(Int((state.at * fps).rounded()) + 1) of \(Int((state.length * fps).rounded(.up)) + 1)")
        if stage != (state.width, state.height) || size.numberOfItems == 0 {
            stage = (state.width, state.height)
            fillFormats()
        }
        timeline.range = state.range
        rangeChip.isHidden = state.range == nil
        if let r = state.range { rangeChip.title = String(format: "⟲ %.1f–%.1f s  ×", r.lowerBound, r.upperBound) }
        exportOptions.range = state.range
        timeline.setCaptions(state.captions)
        timeline.set(
            at: state.at, length: state.length, scenes: state.scenes, tracks: state.tracks, marks: state.marks)
        scenes = state.scenes
        tracks = state.tracks
    }

    /// The element chosen on the page, whose lane stands out ("" for none).
    func chose(_ id: String) { timeline.chosen = id }

    private func toggleLoop() {
        looping.toggle()
        // On speaks through the filled symbol, as the system's switches do.
        loop.image = .symbol(looping ? "repeat.circle.fill" : "repeat", String(localized: "Play Again at the End"))
        loop.toolTip =
            looping
            ? String(localized: "Play Again at the End: On") : String(localized: "Play Again at the End")
        act("window.kelpMotion?.setLoop(\(looping))")
    }

    static let rates = [0.25, 0.5, 1, 1.5, 2]

    @objc private func speedChosen() {
        let rate = Self.rates[max(speed.indexOfSelectedItem, 0)]
        playbackRate = rate
        act("window.kelpMotion?.setRate(\(rate))")
    }

    /// The stage's shapes: a ratio and its size in pixels.
    static let formats: [(name: String, width: Int, height: Int)] = [
        ("16:9", 1920, 1080), ("9:16", 1080, 1920), ("1:1", 1080, 1080), ("4:5", 1080, 1350)
    ]

    /// The shapes, the stage's own chosen; a size that is none of them comes first, as it is.
    private func fillFormats() {
        size.removeAllItems()
        if !Self.formats.contains(where: { ($0.width, $0.height) == stage }) {
            size.addItem(withTitle: "\(stage.width) × \(stage.height)")
        }
        for f in Self.formats { size.addItem(withTitle: "\(f.name) · \(f.width) × \(f.height)") }
        let own = Self.formats.firstIndex { ($0.width, $0.height) == stage }
        let shown = own.map { $0 + size.numberOfItems - Self.formats.count } ?? 0
        // What a change of shape does to what's drawn: fit it, fill with it, or leave it.
        size.menu?.addItem(.separator())
        size.menu?.addItem(.sectionHeader(title: String(localized: "When Changing")))
        for (way, title) in [
            (StageReframe.fit, String(localized: "Fit")), (.fill, String(localized: "Fill")),
            (.none, String(localized: "As It Is"))
        ] {
            let item = NSMenuItem(title: title, action: #selector(reframeChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = way.rawValue
            item.state = reframe == way ? .on : .off
            size.menu?.addItem(item)
        }
        size.menu?.addItem(.separator())
        let other = NSMenuItem(
            title: String(localized: "Also in Other Formats…"), action: #selector(adaptChosen), keyEquivalent: "")
        other.target = self
        size.menu?.addItem(other)
        size.selectItem(at: shown)
    }

    /// What a change of the stage's shape does to what's drawn on it (`StageReframe`).
    private(set) var reframe = StageReframe.fit

    /// Also in Other Formats…: the tab asks which, and the agent makes them.
    var onAdapt: (() -> Void)?
    @objc private func adaptChosen() {
        fillFormats()
        onAdapt?()
    }

    @objc private func reframeChosen(_ item: NSMenuItem) {
        reframe = (item.representedObject as? String).flatMap(StageReframe.init(rawValue:)) ?? .fit
        fillFormats()
    }

    @objc private func formatChosen() {
        let i = size.indexOfSelectedItem - (size.numberOfItems - Self.formats.count)
        guard Self.formats.indices.contains(i) else { return }
        onFormat?(Self.formats[i].width, Self.formats[i].height)
    }

    /// Opens Export Video's popover under its button (the command does it too).
    func openExport() { chooseExport() }

    private func chooseExport() {
        let popover = MotionExportPopover(exportOptions, stage: stage, recent: exports) { [weak self] options in
            guard let self else { return }
            exportOptions = options
            fps = options.rate
            act("window.kelpMotion?.setFPS(\(fps))")
            onExport?(options)
        }
        exportPopover = popover
        popover.show(below: export)
    }

    /// 0.25 as `0.25×`, 1 as `1×`.
    static func rate(_ value: Double) -> String { String(format: "%g×", value) }

    @objc private func zoomSlid() { timeline.setZoom(pow(2, zoomSlider.doubleValue)) }

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
