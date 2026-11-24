import AppKit
import Core
import KelpKit

/// A motion page's subtitles (`Captions`): an SRT or a WebVTT file dropped on the stage becomes their block, a lane on
/// the timeline whose cues move and trim like scenes; Edit's column sets how they look; an export writes them beside
/// the video as SRT.
extension MarkdownTab {
    func importCaptions(_ file: URL) async {
        guard let read = await app.call(FilesRead(path: file.path)) else { return }
        let cues = Captions.parse(read.text)
        guard !cues.isEmpty else {
            return Banner.show(String(localized: "No subtitles in “\(file.lastPathComponent)”."), style: .error)
        }
        let edit = HandEdit(board: pageFile, id: "captions", what: "subtitles", from: nil, to: file.lastPathComponent)
        rewritePage(edit) { Captions.write($0, cues: cues) }
    }

    func captionsMessage(_ kind: String, _ body: [String: Any]) -> Bool {
        guard kind == "captionMenu" || kind == "captionSize" else { return false }
        let now = (Captions.attribute(editor.text) ?? "box bottom 48").split(separator: " ").map(String.init)
        var look = now.count == 3 ? now : ["box", "bottom", "48"]
        let set = { [weak self] (parts: [String]) in
            guard let self else { return }
            let edit = HandEdit(
                board: pageFile, id: "captions", what: "look", from: now.joined(separator: " "),
                to: parts.joined(separator: " "))
            rewritePage(edit) { Captions.setLook($0, parts.joined(separator: " ")) }
        }
        if kind == "captionSize" {
            look[2] = String(max(12, min(200, (body["size"] as? NSNumber)?.intValue ?? 48)))
            set(look)
            return true
        }
        let place = body["field"] as? String == "place"
        let menu = NSMenu()
        for option in place ? Captions.places : Captions.looks {
            menu.add(Self.captionTitle(option)) {
                var next = look
                next[place ? 1 : 0] = option
                set(next)
            }.state = look[place ? 1 : 0] == option ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return true
    }

    static func captionTitle(_ option: String) -> String {
        switch option {
        case "box": String(localized: "Box")
        case "plain": String(localized: "Plain")
        case "outline": String(localized: "Outline")
        case "highlight": String(localized: "Highlight")
        case "top": String(localized: "Top")
        case "middle": String(localized: "Middle")
        default: String(localized: "Bottom")
        }
    }

    /// Writes the page's subtitles beside video `video` as SRT, when it has any.
    func writeSRT(beside video: URL) async {
        let srt = Captions.srt(editor.text)
        guard !srt.isEmpty else { return }
        let path = video.deletingPathExtension().appendingPathExtension("srt").path
        _ = await app.call(FilesWrite(path: path, text: srt, base: nil))
    }
}
