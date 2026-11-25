import Core
import Foundation
import KelpKit

/// A mark on an element with no data-id comes named by its tag and place (`img@3`). Before the marks are kept, Kelp
/// writes that element a data-id in its board (`BoardEdit.giveID`), so the mark finds it again after the agent
/// rewrites the board; one that can't be written keeps its tag.
extension MarkdownTab {
    func stampIDs(_ drafts: [ArtifactMark]) async -> [ArtifactMark] {
        var out = drafts
        for i in out.indices where out[i].kind == .element {
            guard let (tag, index) = Self.placed(out[i].target) else { continue }
            out[i].target = await stamp(out[i].board, tag, index).map { "[data-id=\($0)]" } ?? tag
        }
        return out
    }

    /// `img@3` as the tag and its place among the body's elements of that tag.
    static func placed(_ target: String) -> (String, Int)? {
        let parts = target.split(separator: "@")
        guard parts.count == 2, let index = Int(parts[1]), !parts[0].isEmpty else { return nil }
        return (String(parts[0]), index)
    }

    /// Writes element `index` of `tag` in `board` a data-id (or finds the one it has), and returns it.
    private func stamp(_ board: String, _ tag: String, _ index: Int) async -> String? {
        let path = url.deletingLastPathComponent().appendingPathComponent(board).path
        if path == url.path {   // a motion page's stage is the tab's own file
            guard let given = BoardEdit.giveID(editor.text, tag: tag, index: index) else { return nil }
            if given.text != editor.text {
                editor.apply(text: given.text, selection: NSRange(location: 0, length: 0))
                _ = await saveFile?()
            }
            return given.id
        }
        guard let file = await app.call(FilesRead(path: path)),
            let given = BoardEdit.giveID(file.text, tag: tag, index: index)
        else { return nil }
        if given.text == file.text { return given.id }
        let written = await app.call(FilesWrite(path: path, text: given.text, base: file.stamp))
        return written?.conflict == nil && written?.missing != true ? given.id : nil
    }
}
