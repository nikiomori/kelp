import AppKit
import Core
import DesignKit
import KelpKit

/// A hand edit as a step ⌘Z takes back: each file it changed, its text before and after, and the edit as the agent
/// hears of it. One change on several boards (All like this) is one step (`by`).
struct HandStep {
    struct Part {
        var path: String, before: String, after: String, edit: HandEdit
    }
    var parts: [Part]
    var by: UUID?
}

/// ⌘Z and ⇧⌘Z for what the user changed by hand on a canvas's boards or a motion page. Each step puts the whole file
/// back, so it can't take back something the agent wrote since: then the steps are dropped and the banner says so.
extension MarkdownTab {
    /// Keeps a hand edit written to `path` for the agent (`keepHandEdit`) and as a step ⌘Z takes back; one made by the
    /// same change `by` as the last step joins it. A new edit clears what ⇧⌘Z would bring again.
    func didHandEdit(_ edit: HandEdit, path: String, before: String, after: String, by change: UUID? = nil) {
        keepHandEdit(edit)
        let part = HandStep.Part(path: path, before: before, after: after, edit: edit)
        if let change, handSteps.undo.last?.by == change {
            handSteps.undo[handSteps.undo.count - 1].parts.append(part)
        } else {
            handSteps.undo.append(HandStep(parts: [part], by: change))
        }
        handSteps.redo = []
    }

    /// Takes back the last hand edit, or with `redo` brings back the last one taken back.
    func undoHandEdit(redo: Bool) {
        guard let step = redo ? handSteps.redo.popLast() : handSteps.undo.popLast() else { return NSSound.beep() }
        Task {
            for part in redo ? step.parts : step.parts.reversed() {
                let (from, to) = redo ? (part.before, part.after) : (part.after, part.before)
                guard await write(part.path, from: from, to: to) else {
                    handSteps = ([], [])
                    return Banner.show(
                        String(localized: "The page changed since that edit, so it can’t be taken back."))
                }
                var edit = part.edit
                if !redo { (edit.from, edit.to) = (edit.to, edit.from) }
                keepHandEdit(edit)
            }
            if redo { handSteps.undo.append(step) } else { handSteps.redo.append(step) }
        }
    }

    /// Writes `to` into `path` if the file holds `from` now. The page in this tab goes through its editor, so the
    /// source shown stays in step.
    private func write(_ path: String, from: String, to: String) async -> Bool {
        if path == url.path {
            guard editor.text == from else { return false }
            _ = await save(to).value
            return true
        }
        guard let file = await app.call(FilesRead(path: path)), file.text == from,
            let written = await app.call(FilesWrite(path: path, text: to, base: file.stamp))
        else { return false }
        return written.conflict == nil && written.missing != true
    }
}
