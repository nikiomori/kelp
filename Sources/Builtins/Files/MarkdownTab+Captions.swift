import AppKit
import Core
import DesignKit
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

    /// Subtitles from Text…: the lines typed become the subtitles, each on as long as it is long, over the work area
    /// or from the time shown to the end, their edges on the music's beats where one is near.
    func typedCaptions() {
        Task {
            let alert = NSAlert()
            alert.messageText = String(localized: "Subtitles from Text")
            alert.informativeText = String(
                localized:
                    "Each line is a subtitle. They share the work area, or the rest from the time shown, by length.")
            let scroll = NSTextView.scrollableTextView()
            scroll.frame.size = NSSize(width: Metrics.alertAccessory, height: Metrics.alertAccessory / 2)
            scroll.borderType = .bezelBorder
            let text = scroll.documentView as? NSTextView
            text?.font = .ui(TextSize.row)
            alert.accessoryView = scroll
            alert.addButton(withTitle: String(localized: "Make Subtitles"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.window.initialFirstResponder = text
            guard await runSheet(alert) == .alertFirstButtonReturn, let typed = text?.string else { return }
            let cues = Captions.timed(typed, over: motionStudio.captionSpan, beats: pageBeats())
            guard !cues.isEmpty else { return }
            let edit = HandEdit(
                board: pageFile, id: "captions", what: "subtitles", from: nil, to: "\(cues.count) typed")
            rewritePage(edit) { Captions.write($0, cues: cues) }
        }
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

    /// Writes the page's subtitles beside video `video` as SRT, when it has any, timed as the video made of `span`.
    func writeSRT(beside video: URL, over span: ClosedRange<Double>) async {
        let srt = Captions.srt(editor.text, over: span)
        guard !srt.isEmpty else { return }
        let path = video.deletingPathExtension().appendingPathExtension("srt").path
        _ = await app.call(FilesWrite(path: path, text: srt, base: nil))
    }
}
