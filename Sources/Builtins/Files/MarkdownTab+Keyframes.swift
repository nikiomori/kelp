import AppKit
import Core
import DesignKit
import KelpKit

/// Keyframes of a motion page's elements, by hand. K (or ◆ in the studio's row) puts a keyframe of the chosen element
/// at the time shown with its look then, or takes away the one there; an element with no animation gets one, from the
/// time shown for a second. A keyframe's diamond is dragged on its lane, and its menu sets the easing of the stretch
/// after it, moves it to the time, or deletes it. A drag of the element on the stage while its animation runs moves it
/// at that keyframe. All of it is the page's @keyframes rule (`CSSKeyframes`), as hand edits.
extension MarkdownTab {
    /// The easings the menu offers, by name; spring and back as CSS can play them.
    static let easings: [(name: String, value: String)] = [
        ("Linear", "linear"), ("Ease In", "ease-in"), ("Ease Out", "ease-out"), ("Ease In Out", "ease-in-out"),
        ("Back Out", "cubic-bezier(.34, 1.56, .64, 1)"),
        ("Spring", "linear(0, .25 6%, .66 13%, 1.04 22%, 1.13 29%, 1.08 37%, .99 47%, .97 57%, 1 70%, 1)")
    ]

    /// The element K acts on: the one chosen on the stage, or else the lane clicked last.
    private var keyed: MotionTimeline.Clip? {
        let id = chosen?.id ?? motionStudio.picked
        return motionStudio.tracks.first { $0.id == id && !$0.id.isEmpty }
    }

    /// K: a keyframe of the chosen element at the time shown, or the one there taken away.
    func keyframe() {
        guard let clip = keyed else {
            return Banner.show(String(localized: "Choose an element to give it a keyframe."))
        }
        let at = motionStudio.at
        if let keys = clip.keys {
            let place = (keys.place(at) * 10).rounded() / 10
            guard (0...100).contains(place) else {
                return Banner.show(String(localized: "The time is outside the element’s animation."))
            }
            if let there = keys.at.first(where: { abs($0 - place) < 0.6 }) {
                return there > 0 && there < 100
                    ? changeFrames(clip.id, keys.name, "keyframe removed") {
                        $0.filter { abs($0.at - there) > 0.01 }
                    } : NSSound.beep()
            }
            Task { await addFrame(clip.id, keys.name, place) }
        } else {
            Task { await animate(clip.id, from: at) }
        }
    }

    private func values(_ id: String) async -> [CSSKeyframes.Declaration] {
        let got: Any?
        do {
            got = try await web.callAsyncJavaScript(
                "return window.kelpMotion?.values(id)", arguments: ["id": id], contentWorld: Self.world)
        } catch { got = nil }   // a page not drawn yet gives nothing: the keyframe waits for a look
        return ((got as? [String: String]) ?? [:]).sorted { $0.key < $1.key }.map {
            CSSKeyframes.Declaration(property: $0.key, value: $0.value.replacingOccurrences(of: "\"", with: "'"))
        }
    }

    private func addFrame(_ id: String, _ name: String, _ place: Double) async {
        let declarations = await values(id)
        changeFrames(id, name, "keyframe at \(CSSKeyframes.percent(place))") {
            $0 + [CSSKeyframes.Frame(at: place, declarations: declarations)]
        }
    }

    /// An element with no animation gets one: from `at`, a second long, its look now at both ends.
    private func animate(_ id: String, from at: Double) async {
        let declarations = await values(id), name = "\(id)-motion"
        let edit = HandEdit(board: pageFile, id: id, what: "animation", from: nil, to: name)
        rewritePage(edit) { text in
            CSSKeyframes.add(
                text, name: name,
                frames: [.init(at: 0, declarations: declarations), .init(at: 100, declarations: declarations)]
            ).flatMap {
                BoardEdit.setStyle($0, id: id, property: "animation", value: "\(name) 1s \(Self.seconds(at))s both")
            }
        }
    }

    /// Changes rule `name`'s keyframes with `change`, as one hand edit of element `id`.
    func changeFrames(
        _ id: String, _ name: String, _ what: String, _ change: @escaping ([CSSKeyframes.Frame]) -> [CSSKeyframes.Frame]
    ) {
        rewritePage(HandEdit(board: pageFile, id: id, what: what, from: nil, to: name)) { text in
            CSSKeyframes.frames(text, name: name).flatMap { CSSKeyframes.write(text, name: name, frames: change($0)) }
        }
    }

    /// Moves element `id`'s keyframe from place `from` to `to`.
    func moveKeyframe(_ id: String, from: Double, to: Double) {
        guard let keys = motionStudio.tracks.first(where: { $0.id == id })?.keys else { return }
        changeFrames(id, keys.name, "keyframe moved to \(CSSKeyframes.percent(to))") { frames in
            frames.map { frame in
                var moved = frame
                if abs(frame.at - from) < 0.01 { moved.at = to }
                return moved
            }
        }
    }

    /// Sets the easing of the stretch after element `id`'s keyframe at `place` (nil: the animation's own).
    func easeKeyframe(_ id: String, at place: Double, _ easing: String?) {
        guard let keys = motionStudio.tracks.first(where: { $0.id == id })?.keys else { return }
        changeFrames(id, keys.name, "easing at \(CSSKeyframes.percent(place))") { frames in
            frames.map { frame in
                var eased = frame
                if abs(frame.at - place) < 0.01 { eased.set("animation-timing-function", easing) }
                return eased
            }
        }
    }

    /// A keyframe's menu: the easing after it, move it to the time, edit its curve, delete it.
    func keyframeMenu(_ id: String, _ place: Double) -> NSMenu? {
        guard let keys = motionStudio.tracks.first(where: { $0.id == id })?.keys else { return nil }
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: String(localized: "Easing After It")))
        let now = keys.at.firstIndex { abs($0 - place) < 0.01 }.flatMap {
            keys.easing.indices.contains($0) ? keys.easing[$0] : nil
        }
        for easing in Self.easings {
            menu.add(String(localized: String.LocalizationValue(easing.name))) { [weak self] in
                self?.easeKeyframe(id, at: place, easing.value)
            }.state = now == easing.value ? .on : .off
        }
        menu.add(String(localized: "Edit Curve…")) { [weak self] in
            self?.runJS("window.kelpCurve?.(\(Self.js(id)), \(place))")
        }
        menu.addItem(.separator())
        let time = motionStudio.at, there = (keys.place(time) * 10).rounded() / 10
        if place > 0, place < 100, (0...100).contains(there) {
            menu.add(String(localized: "Move to the Time")) { [weak self] in
                self?.moveKeyframe(id, from: place, to: there)
            }
        }
        if place > 0, place < 100 {
            menu.add(String(localized: "Delete Keyframe")) { [weak self] in
                self?.changeFrames(id, keys.name, "keyframe removed") { $0.filter { abs($0.at - place) > 0.01 } }
            }
        }
        return menu
    }

    /// The element dragged on the stage while its animation runs: its place at the time shown, in that keyframe
    /// (made if there is none).
    func keyframeTranslate(_ id: String, _ translate: String) {
        guard let keys = motionStudio.tracks.first(where: { $0.id == id })?.keys else { return }
        let place = (keys.place(motionStudio.at) * 10).rounded() / 10
        guard (0...100).contains(place) else { return NSSound.beep() }
        changeFrames(id, keys.name, "moved at \(CSSKeyframes.percent(place))") { frames in
            var out = frames
            if let i = out.firstIndex(where: { abs($0.at - place) < 0.6 }) {
                out[i].set("translate", translate)
            } else {
                out.append(.init(at: place, declarations: [.init(property: "translate", value: translate)]))
            }
            return out
        }
    }

    /// The words of the column's Motion section and its curve.
    var motionKeyLabels: [String: String] {
        [
            "motion": String(localized: "Motion"), "keyframes": String(localized: "Keyframes"),
            "easing": String(localized: "Easing"), "curve": String(localized: "Curve"),
            "spring": String(localized: "Spring"), "wiggle": String(localized: "Wiggle"),
            "bounce": String(localized: "Bounce"), "count": String(localized: "Swings"),
            "presets": String(localized: "Ready Ones"), "entrance": String(localized: "Entrance and Exit"),
            "comes": String(localized: "Comes In"), "goes": String(localized: "Goes Out"),
            "length": String(localized: "Length"), "fade": String(localized: "Fade"),
            "rise": String(localized: "Rise"), "pop": String(localized: "Pop"),
            "letters": String(localized: "By Letters"), "words": String(localized: "By Words"),
            "fade-out": String(localized: "Fade"), "rise-out": String(localized: "Rise Away")
        ]
    }
}
