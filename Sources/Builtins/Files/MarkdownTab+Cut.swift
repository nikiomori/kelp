import AppKit
import Core
import KelpKit

/// Cutting a motion page's clips at the time shown, as a video editor does: S splits a clip in two there, ⇤ and ⇥ trim
/// its start or end to it, and ⌘C ⌘X ⌘V copy, cut and paste clips. A clip here is anything with its own time (a scene,
/// a picture, a video: `data-start`, `data-duration`); the half after a split is a copy that goes on from where the
/// first stops, as its animations keep the page's time.
extension MarkdownTab {
    /// The pasteboard type of a clip copied from a motion page: its element's HTML.
    static let clipType = NSPasteboard.PasteboardType("com.kelp.motion-clip")

    /// The clip with its own time that `id` names, or else the scene the time shown is in.
    private func timed(_ id: String?) -> MotionTimeline.Clip? {
        let all = motionStudio.scenes + motionStudio.tracks.filter(\.delays.isEmpty)
        if let id, let clip = all.first(where: { $0.id == id }) { return clip }
        let at = motionStudio.at
        return motionStudio.scenes.first { $0.start <= at && at < $0.end }
    }

    /// Splits clip `id` (or the scene under the time) at the time shown.
    func splitClip(_ id: String?) {
        let at = motionStudio.at
        guard let clip = timed(id), clip.start + 0.05 < at, at < clip.end - 0.05 else { return NSSound.beep() }
        let edit = HandEdit(board: pageFile, id: clip.id, what: "split at", from: nil, to: Self.seconds(at))
        rewritePage(edit) { text in
            guard let copy = BoardEdit.duplicate(text, id: clip.id) else { return nil }
            return BoardEdit.setAttribute(
                copy.text, id: clip.id, name: "data-duration", value: Self.seconds(at - clip.start)
            )
            .flatMap { BoardEdit.setAttribute($0, id: copy.id, name: "data-start", value: Self.seconds(at)) }
            .flatMap {
                BoardEdit.setAttribute($0, id: copy.id, name: "data-duration", value: Self.seconds(clip.end - at))
            }
        }
    }

    /// Trims the start (or with `end`, the end) of clip `id` (or the scene under the time) to the time shown.
    func trimClip(_ id: String?, end: Bool) {
        let at = motionStudio.at
        guard let clip = timed(id), clip.start < at, at < clip.end else { return NSSound.beep() }
        var now = clip
        if end { now.length = at - clip.start } else { (now.start, now.length) = (at, clip.end - at) }
        retime(scene: clip, as: now)
    }

    /// Copies clip `id` (with `cut`, takes it out too).
    func copyClip(_ id: String?, cut: Bool) {
        guard let clip = timed(id), let html = BoardEdit.element(editor.text, id: clip.id) else {
            return NSSound.beep()
        }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(html, forType: Self.clipType)
        board.setString(html, forType: .string)
        if cut { removeElement(pageFile, clip.id) }
    }

    /// Pastes the clip copied at the time shown, as a new element at the end of the page's body.
    func pasteClip() {
        guard let html = NSPasteboard.general.string(forType: Self.clipType) else { return NSSound.beep() }
        let at = Self.seconds(motionStudio.at)
        let edit = HandEdit(board: pageFile, id: "body", what: "pasted at", from: nil, to: at)
        rewritePage(edit) { text in
            guard let copy = BoardEdit.renamed(html, in: text) else { return nil }
            return BoardEdit.setAttribute(
                BoardEdit.appendToBody(text, copy.html), id: copy.id, name: "data-start", value: at)
        }
    }
}
