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

    /// Copies clips `ids` (or the one under the time), and with `cut` takes them out too. Kept as their HTML and start.
    func copyClips(_ ids: [String], cut: Bool) {
        let clips = ids.isEmpty ? timed(nil).map { [$0] } ?? [] : ids.compactMap { timed($0) }
        let items = clips.compactMap { clip in
            BoardEdit.element(editor.text, id: clip.id).map { ["html": $0, "start": Self.seconds(clip.start)] }
        }
        let data: Data
        do { data = try JSONSerialization.data(withJSONObject: items) } catch { return NSSound.beep() }
        guard !items.isEmpty else { return NSSound.beep() }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(data, forType: Self.clipType)
        board.setString(items.compactMap { $0["html"] }.joined(separator: "\n"), forType: .string)
        if cut { removeElements(clips.map(\.id)) }
    }

    /// Copies clip `id` (with `cut`, takes it out too).
    func copyClip(_ id: String?, cut: Bool) { copyClips(id.map { [$0] } ?? [], cut: cut) }

    /// Pastes the clips copied at the time shown, keeping how far apart they were, each a new element at the end of
    /// the page's body.
    func pasteClip() {
        let copied = NSPasteboard.general.data(forType: Self.clipType)
        let items: [[String: String]]
        do {
            items = try copied.map { try JSONSerialization.jsonObject(with: $0) } as? [[String: String]] ?? []
        } catch {
            items = []   // what isn't Kelp's clips pastes nothing
        }
        guard !items.isEmpty else { return NSSound.beep() }
        let first = items.compactMap { Double($0["start"] ?? "") }.min() ?? 0, at = motionStudio.at
        let edit = HandEdit(board: pageFile, id: "body", what: "pasted at", from: nil, to: Self.seconds(at))
        rewritePage(edit) { text in
            items.reduce(Optional(text)) { text, item in
                guard let text, let html = item["html"], let copy = BoardEdit.renamed(html, in: text) else {
                    return nil
                }
                let start = at + (Double(item["start"] ?? "") ?? first) - first
                return BoardEdit.setAttribute(
                    BoardEdit.appendToBody(text, copy.html), id: copy.id, name: "data-start", value: Self.seconds(start)
                )
            }
        }
    }

    /// Takes elements `ids` out of the page, as one edit.
    func removeElements(_ ids: [String]) {
        guard let first = ids.first else { return }
        let edit = HandEdit(
            board: pageFile, id: first, what: ids.count > 1 ? "removed \(ids.count)" : "removed", from: nil, to: nil)
        rewritePage(edit) { text in
            ids.reduce(Optional(text)) { text, id in text.flatMap { BoardEdit.remove($0, id: id) } }
        }
    }
}
