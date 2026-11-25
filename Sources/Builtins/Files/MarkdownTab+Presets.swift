import AppKit
import Core
import KelpKit

/// A motion page's element entrance and exit by hand (`MotionPresets`), from Edit's column: which, how long, how
/// eased. An entrance starts with the element's scene, an exit ends with it; each is a hand edit of the page.
extension MarkdownTab {
    func presetsMessage(_ kind: String, _ body: [String: Any]) -> Bool {
        guard ["animMenu", "animLength"].contains(kind), let id = body["id"] as? String,
            let which = (body["which"] as? String).flatMap(MotionPresets.Which.init(rawValue:))
        else { return false }
        let now = MotionPresets.parse(body["now"] as? String ?? "")
        let had = !(body["now"] as? String ?? "").isEmpty
        let span = ((body["start"] as? NSNumber)?.doubleValue ?? 0, (body["end"] as? NSNumber)?.doubleValue ?? 1)
        let set = { [weak self] (preset: String?, length: Double, easing: String) in
            let start = which == .entrance ? span.0 : max(span.0, span.1 - length)
            self?.setPreset(id, which, .init(preset, length: length, easing: easing, start: start))
        }
        let length = Double(now.length) ?? 0.6
        if kind == "animLength" {
            set(now.name, (body["length"] as? NSNumber)?.doubleValue ?? length, now.easing)
            return true
        }
        let menu = NSMenu()
        if body["field"] as? String == "ease" {
            for (title, value) in [
                ("Even Speed", "linear"), ("Ease In", "ease-in"), ("Ease Out", "ease-out"),
                ("Ease In Out", "ease-in-out"),
                ("Back Out", "cubic-bezier(.34,1.56,.64,1)")
            ] {
                menu.add(String(localized: String.LocalizationValue(title))) { set(now.name, length, value) }
                    .state = now.easing == value ? .on : .off
            }
        } else {
            menu.add(String(localized: "None")) { set(nil, length, now.easing) }.state = had ? .off : .on
            let names = which == .entrance ? MotionPresets.entrances : MotionPresets.exits
            for name in names {
                menu.add(Self.presetTitle(name)) { set(name, had ? length : 0.6, had ? now.easing : "ease-out") }
                    .state = had && now.name == name ? .on : .off
            }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return true
    }

    static func presetTitle(_ name: String) -> String {
        switch name {
        case "fade", "fade-out": String(localized: "Fade")
        case "rise": String(localized: "Rise")
        case "rise-out": String(localized: "Rise Away")
        case "pop": String(localized: "Pop")
        case "letters": String(localized: "By Letters")
        default: String(localized: "By Words")
        }
    }

    private func setPreset(_ id: String, _ which: MotionPresets.Which, _ choice: MotionPresets.Choice) {
        let edit = HandEdit(
            board: pageFile, id: id, what: which == .entrance ? "entrance" : "exit", from: nil, to: choice.preset)
        rewritePage(edit) { MotionPresets.set($0, id: id, which, choice) }
    }

    /// The ready parts a motion page takes at the playhead (`MotionBlocks`), four seconds each.
    func blocksMenu() -> NSMenu {
        let menu = NSMenu()
        for name in MotionBlocks.names {
            menu.add(Self.blockTitle(name)) { [weak self] in
                guard let self else { return }
                let id = BoardEdit.freeID(editor.text, name), start = motionStudio.at
                let stage = MotionPage.size(editor.text)
                rewritePage(HandEdit(board: pageFile, id: id, what: "added", from: nil, to: name)) {
                    MotionBlocks.add($0, name, id: id, time: start...start + 4, stage: stage)
                }
            }
        }
        return menu
    }

    static func blockTitle(_ name: String) -> String {
        switch name {
        case "name": String(localized: "Name Plate")
        case "title": String(localized: "Title Card")
        case "quote": String(localized: "Quote")
        case "figure": String(localized: "Big Number")
        case "section": String(localized: "Section Title")
        case "progress": String(localized: "Progress Bar")
        case "action": String(localized: "Call to Action")
        default: String(localized: "End Card")
        }
    }
}
