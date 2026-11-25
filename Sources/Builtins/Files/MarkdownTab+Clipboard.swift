import AppKit
import Core
import KelpKit

/// ⌘C and ⌘V on a canvas's or motion page's chosen element, as in any editor: an element copied goes in after the
/// chosen one, on this board or another, its data-ids numbered anew; a picture copied anywhere (a screenshot) goes in
/// as an image after it, or becomes the chosen image's picture.
extension MarkdownTab {
    static let elementType = NSPasteboard.PasteboardType("com.kelp.element")

    func copyElement(_ board: String, _ id: String) {
        Task {
            guard let source = await boardText(board), let html = BoardEdit.element(source, id: id) else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(html, forType: Self.elementType)
            pasteboard.setString(html, forType: .string)
        }
    }

    func pasteElement(_ board: String, after id: String) {
        let pasteboard = NSPasteboard.general
        if let html = pasteboard.string(forType: Self.elementType) { return put(html, on: board, after: id) }
        guard let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return NSSound.beep() }
        Task {
            guard let source = await boardText(board) else { return }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(
                "pasted-\(UUID().uuidString.prefix(6)).png")
            do { try png.write(to: file) } catch { return Banner.show(error.localizedDescription, style: .error) }
            if BoardEdit.element(source, id: id)?.lowercased().hasPrefix("<img") == true {
                return await setImage(board, id, to: file)   // the chosen image takes the picture
            }
            let folder = url.deletingLastPathComponent().path
            guard let made = await app.call(FilesCopy(paths: [file.path], into: folder))?.made.first else { return }
            let name = (made as NSString).lastPathComponent, width = Int(image.size.width)
            put(
                #"<img data-id="picture" src="\#(name)" style="width: \#(width)px; max-width: 100%">"#, on: board,
                after: id)
        }
    }

    /// Puts `html` after element `id` of `board` and chooses it.
    private func put(_ html: String, on board: String, after id: String) {
        let edit = { [weak self] (source: String) -> HandEdit? in
            guard let made = BoardEdit.insert(html, after: id, in: source) else { return nil }
            self?.chosen = (board, made.id)
            return HandEdit(board: board, id: made.id, what: "pasted", from: nil, to: made.id)
        }
        rewrite(board, edit: edit) { BoardEdit.insert(html, after: id, in: $0)?.text }
    }

    private func boardText(_ board: String) async -> String? {
        let path = url.deletingLastPathComponent().appendingPathComponent(board).path
        return path == url.path ? editor.text : await app.quiet(FilesRead(path: path))?.text
    }
}
