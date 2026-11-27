import AppKit
import Core
import KelpKit

/// A transition where two scenes meet, from the seam's menu on the timeline: the next scene starts earlier by the
/// transition's length and comes in over the one going out (`MotionPresets`: fade, slide, wipe, zoom), which goes out
/// in the same time. Removing it puts the next scene back where it began. One hand edit of the page.
extension MarkdownTab {
    static let transitions: [(title: String, in: String, out: String?)] = [
        ("Crossfade", "fade", "fade-out"), ("Slide Left", "slide", "slide-out"), ("Wipe", "wipe", nil),
        ("Push In", "zoom", "zoom-out")
    ]

    func seamMenu(_ out: String, _ into: String) -> NSMenu? {
        let length = 0.4
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: String(localized: "Transition \(MotionVerify.number(length)) s")))
        let now = motionStudio.scenes.first { $0.id == into }?.transition
        for transition in Self.transitions {
            menu.add(String(localized: String.LocalizationValue(transition.title))) { [weak self] in
                self?.setTransition(out, into, transition, length: length)
            }.state = now == transition.in ? .on : .off
        }
        if now != nil {
            menu.addItem(.separator())
            menu.add(String(localized: "Remove Transition")) { [weak self] in
                self?.setTransition(out, into, nil, length: length)
            }
        }
        return menu
    }

    private func setTransition(
        _ out: String, _ into: String, _ kind: (title: String, in: String, out: String?)?, length: Double
    ) {
        guard let outgoing = motionStudio.scenes.first(where: { $0.id == out }),
            let incoming = motionStudio.scenes.first(where: { $0.id == into })
        else { return }
        let edit = HandEdit(board: pageFile, id: into, what: "transition", from: incoming.transition, to: kind?.in)
        rewritePage(edit) { page in
            // Where the scene began before a transition moved it, kept on it.
            let element = BoardEdit.element(page, id: into) ?? ""
            let had = element.firstMatch(of: /data-kelp-overlap="([0-9.]+)"/).flatMap { Double($0.output.1) } ?? 0
            let begins = incoming.start + had, lasts = incoming.length - had
            let overlap = kind == nil ? 0 : length
            let ease = "ease-in-out"
            var text: String? = page
            text = text.flatMap {
                BoardEdit.setAttribute($0, id: into, name: "data-start", value: MotionVerify.number(begins - overlap))
            }
            text = text.flatMap {
                BoardEdit.setAttribute($0, id: into, name: "data-duration", value: MotionVerify.number(lasts + overlap))
            }
            text = text.flatMap {
                BoardEdit.setAttribute(
                    $0, id: into, name: "data-kelp-overlap", value: overlap > 0 ? MotionVerify.number(overlap) : nil)
            }
            text = text.flatMap {
                MotionPresets.set(
                    $0, id: into, .entrance, .init(kind?.in, length: length, easing: ease, start: begins - overlap))
            }
            return text.flatMap {
                MotionPresets.set(
                    $0, id: out, .exit, .init(kind?.out, length: length, easing: ease, start: outgoing.end - length))
            }
        }
    }
}
